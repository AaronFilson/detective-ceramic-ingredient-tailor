# frozen_string_literal: true

require "test_helper"

class BlendsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @clay = UserSample.create!(
      title: "Snohomish River Clay",
      material_category: :wild_clay,
      latitude: 47.9129,
      longitude: -122.0982
    )
    @clay.assay_results.create!(
      source_type: :spatial_heuristic_estimate,
      oxides: {
        "SiO2" => 61.0,
        "Al2O3" => 18.5,
        "Fe2O3" => 4.2,
        "CaO" => 2.1,
        "MgO" => 1.2,
        "Na2O" => 1.0,
        "K2O" => 2.0,
        "LOI" => 10.0
      }
    )

    @ash = UserSample.create!(
      title: "Bigleaf Maple Wood Ash",
      material_category: :wood_ash
    )
    @ash.assay_results.create!(
      source_type: :verified_lab_xrf,
      oxides: {
        "SiO2" => 11.0,
        "Al2O3" => 3.0,
        "Fe2O3" => 1.0,
        "CaO" => 53.0,
        "MgO" => 6.0,
        "Na2O" => 1.0,
        "K2O" => 6.0,
        "P2O5" => 3.0,
        "LOI" => 16.0
      }
    )

    @granite = UserSample.create!(
      title: "Index Quarry Granite",
      material_category: :crushed_rock
    )
    @granite.assay_results.create!(
      source_type: :spatial_heuristic_estimate,
      oxides: {
        "SiO2" => 73.0,
        "Al2O3" => 14.0,
        "Fe2O3" => 1.5,
        "CaO" => 1.0,
        "MgO" => 0.5,
        "Na2O" => 4.2,
        "K2O" => 4.8,
        "LOI" => 1.0
      }
    )

    @unassayed = UserSample.create!(
      title: "Unanalyzed Creek Silt",
      material_category: :wild_clay
    )
  end

  test "GET /blends lists assayed samples, excludes unassayed samples, shows stock modifiers, and previews default blend" do
    get blends_path

    assert_response :success
    assert_includes response.body, "Local Material Glaze Recipe Builder"
    assert_includes response.body, "1A. Your Assayed Local Materials"
    assert_includes response.body, "1B. Studio Stock Modifiers"
    assert_includes response.body, "Fluxes &amp; Frits"
    assert_includes response.body, "Stabilizers, Glass Formers &amp; Colorants"
    assert_includes response.body, "Ferro Frit 3134"
    assert_includes response.body, "Spodumene"
    assert_includes response.body, "Snohomish River Clay"
    assert_includes response.body, "Bigleaf Maple Wood Ash"
    assert_includes response.body, "Index Quarry Granite"
    assert_not_includes response.body, "Unanalyzed Creek Silt"
    assert_includes response.body, 'id="blend_results"'
    assert_includes response.body, "Glazecalc Recipe + Materials Bundle"
    assert_includes response.body, "Glaze Vault Recipe + Materials Archive"
  end

  test "GET /blends auto-reformulates a single wild clay with Cone 6 or Cone 10 studio stock modifiers" do
    @ash.destroy!
    @granite.destroy!

    # Default Cone 6 auto-pairs with Whiting + Ferro Frit 3134
    get blends_path, params: { target_cone: "6", surface: "gloss" }

    assert_response :success
    assert_includes response.body, "1-Wild-Clay Auto-Reformulator"
    assert_includes response.body, "Snohomish River Clay"
    assert_includes response.body, "Whiting (CaCO3)"
    assert_includes response.body, "Ferro Frit 3134"
    assert_includes response.body, "231 Simplex Points"
    assert_includes response.body, "B₂O₃ (mol)"
    assert_includes response.body, "stock_keys%5B%5D=whiting"
    assert_includes response.body, "stock_keys%5B%5D=ferro_frit_3134"

    # Cone 10 auto-pairs with Whiting + EPK Kaolin
    get blends_path, params: { target_cone: "10", surface: "gloss" }

    assert_response :success
    assert_includes response.body, "1-Wild-Clay Auto-Reformulator"
    assert_includes response.body, "EPK Kaolin"
    assert_includes response.body, "stock_keys%5B%5D=epk_kaolin"
  end

  test "POST /blends calculates 2-material line blend via Turbo Stream" do
    post blends_path,
      params: {
        sample_ids: [ @clay.id, @ash.id ],
        target_cone: "10",
        surface: "matte",
        recipe_title: "Snohomish Maple Matte"
      },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, '<turbo-stream action="replace" target="blend_results">'
    assert_includes response.body, "Snohomish Maple Matte"
    assert_includes response.body, "Line Blend"
    assert_includes response.body, "Cone 10 Matte"
    assert_includes response.body, "0% / 100%"
    assert_includes response.body, "100% / 0%"
    assert_includes response.body, "×10⁻⁷"
    assert_includes response.body, "/blends/export_glazecalc"
    assert_includes response.body, "/blends/export_glaze_vault"
  end

  test "POST /blends mixes local wild clay with Studio Stock Modifiers and renders B2O3, COE, and export links" do
    post blends_path,
      params: {
        sample_ids: [ @clay.id ],
        stock_keys: [ "whiting", "ferro_frit_3134" ],
        target_cone: "6",
        surface: "gloss",
        recipe_title: "Snohomish Cone 6 Gloss"
      },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_includes response.body, "Snohomish Cone 6 Gloss"
    assert_includes response.body, "Triaxial Blend"
    assert_includes response.body, "B₂O₃"
    assert_includes response.body, "Balanced Fit"
    assert_includes response.body, "Studio Stock"
    assert_includes response.body, "sample_ids%5B%5D=#{@clay.id}"
    assert_includes response.body, "stock_keys%5B%5D=whiting"
    assert_includes response.body, "stock_keys%5B%5D=ferro_frit_3134"
    assert_not_includes response.body, "Cone 6 Boron Tip"
  end

  test "POST /blends displays Li2O when blending with Spodumene and Cone 6 boron tip when B2O3 is absent" do
    post blends_path,
      params: {
        sample_ids: [ @clay.id ],
        stock_keys: [ "spodumene" ],
        target_cone: "6",
        surface: "gloss"
      }

    assert_response :success
    assert_includes response.body, "Li₂O:"
    assert_includes response.body, "Cone 6 Boron Tip"
  end

  test "POST /blends calculates 3-material triaxial blend and renders top candidates" do
    post blends_path,
      params: {
        sample_ids: [ @clay.id, @ash.id, @granite.id ],
        target_cone: "6",
        surface: "gloss",
        recipe_title: "Cascade Triaxial Gloss"
      }

    assert_response :success
    assert_includes response.body, "Cascade Triaxial Gloss"
    assert_includes response.body, "Triaxial Blend"
    assert_includes response.body, "231 Simplex Points"
    assert_includes response.body, "Cone 6 Gloss"
    assert_includes response.body, "Top 12 Triaxial Candidates"
    assert_includes response.body, "Cone 6 Boron Tip"
  end

  test "POST /blends returns 422 error alert when fewer than 2 or more than 3 total materials are selected" do
    post blends_path,
      params: {
        sample_ids: [ @clay.id ],
        target_cone: "6",
        surface: "gloss"
      },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :unprocessable_content
    assert_includes response.body, "Unable to Calculate Blend"
    assert_includes response.body, "Select 2 materials"

    post blends_path,
      params: {
        sample_ids: [ @clay.id, @ash.id ],
        stock_keys: [ "whiting", "ferro_frit_3134" ],
        target_cone: "6",
        surface: "gloss"
      }

    assert_response :unprocessable_content
    assert_includes response.body, "Unable to Calculate Blend"
  end

  test "GET /blends/export_glazecalc downloads valid glazecalc-export v1 bundle" do
    get export_glazecalc_blends_path,
      params: {
        sample_ids: [ @clay.id, @ash.id, @granite.id ],
        target_cone: "6",
        surface: "gloss",
        recipe_title: "Puget Triaxial Gloss"
      }

    assert_response :success
    assert_includes response.media_type, "application/json"
    assert_equal(
      'attachment; filename="puget-triaxial-gloss-glazecalc-bundle.json"',
      response.headers["Content-Disposition"]
    )

    body = JSON.parse(response.body)
    assert_equal "glazecalc-export", body["format"]
    assert_equal 1, body["version"]
    assert_equal 3, body.dig("records", "materials").size
    assert_equal 1, body.dig("records", "recipes").size
    assert_equal "Puget Triaxial Gloss", body.dig("records", "recipes", 0, "title")
    assert_equal "mid", body.dig("records", "recipes", 0, "firing")
    assert_equal 100, body.dig("records", "recipes", 0, "materials").sum { |m| m["amount"] }
  end

  test "GET /blends/export_glaze_vault downloads valid glaze-vault-export v1 archive" do
    get export_glaze_vault_blends_path,
      params: {
        sample_ids: [ @clay.id, @ash.id ],
        target_cone: "10",
        surface: "matte",
        recipe_title: "High Fire Ash Matte"
      }

    assert_response :success
    assert_includes response.media_type, "application/json"
    assert_equal(
      'attachment; filename="high-fire-ash-matte-glaze-vault-bundle.json"',
      response.headers["Content-Disposition"]
    )

    body = JSON.parse(response.body)
    assert_equal "glaze-vault-export", body["format"]
    assert_equal 1, body["version"]
    assert_equal 2, body["materials"].size
    assert_equal 1, body["recipes"].size

    recipe = body["recipes"].first
    assert_equal "High Fire Ash Matte", recipe["name"]
    assert_equal "glaze", recipe["type"]
    assert_equal "10", recipe["cone"]
    assert_equal "matte", recipe["surface"]
    assert_equal 100, recipe["lines"].sum { |l| l["amount"] }
  end

  test "export endpoints serialize mixed local samples and stock modifiers cleanly" do
    get export_glazecalc_blends_path,
      params: {
        sample_ids: [ @clay.id ],
        stock_keys: [ "whiting", "ferro_frit_3134" ],
        target_cone: "6",
        surface: "gloss",
        recipe_title: "Snohomish Frit 3134 Gloss"
      }

    assert_response :success
    gc_body = JSON.parse(response.body)
    assert_equal [ "Snohomish River Clay", "Whiting (CaCO3)", "Ferro Frit 3134" ],
      gc_body.dig("records", "materials").map { |m| m["name"] }
    assert_includes gc_body.dig("records", "recipes", 0, "notes"), "B2O3"
    assert_includes gc_body.dig("records", "recipes", 0, "notes"), "Predicted COE:"

    get export_glaze_vault_blends_path,
      params: {
        sample_ids: [ @clay.id ],
        stock_keys: [ "whiting", "ferro_frit_3134" ],
        target_cone: "6",
        surface: "gloss",
        recipe_title: "Snohomish Frit 3134 Gloss"
      }

    assert_response :success
    gv_body = JSON.parse(response.body)
    assert_equal 3, gv_body["materials"].size
    assert_equal %w[whiting ferro_frit_3134], gv_body.dig("provenance", "stock_keys")
    assert_includes gv_body.dig("recipes", 0, "notes"), "Predicted COE:"
  end

  test "export endpoints return 422 JSON when sample selection is invalid" do
    get export_glazecalc_blends_path, params: { sample_ids: [ @clay.id ] }
    assert_response :unprocessable_content
    assert_includes JSON.parse(response.body)["error"], "Select 2 materials"

    get export_glaze_vault_blends_path, params: { sample_ids: [] }
    assert_response :unprocessable_content
    assert_includes JSON.parse(response.body)["error"], "Select 2 materials"
  end
end
