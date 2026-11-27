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

  test "GET /blends lists assayed samples, excludes unassayed samples, and previews default blend" do
    get blends_path

    assert_response :success
    assert_includes response.body, "Local Material Glaze Recipe Builder"
    assert_includes response.body, "Snohomish River Clay"
    assert_includes response.body, "Bigleaf Maple Wood Ash"
    assert_includes response.body, "Index Quarry Granite"
    assert_not_includes response.body, "Unanalyzed Creek Silt"
    assert_includes response.body, 'id="blend_results"'
    assert_includes response.body, "Glazecalc Recipe + Materials Bundle"
    assert_includes response.body, "Glaze Vault Recipe + Materials Archive"
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
    assert_includes response.body, "/blends/export_glazecalc"
    assert_includes response.body, "/blends/export_glaze_vault"
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
  end

  test "POST /blends returns 422 error alert when fewer than 2 samples are selected" do
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

  test "export endpoints return 422 JSON when sample selection is invalid" do
    get export_glazecalc_blends_path, params: { sample_ids: [ @clay.id ] }
    assert_response :unprocessable_content
    assert_includes JSON.parse(response.body)["error"], "Select 2 materials"

    get export_glaze_vault_blends_path, params: { sample_ids: [] }
    assert_response :unprocessable_content
    assert_includes JSON.parse(response.body)["error"], "Select 2 materials"
  end
end
