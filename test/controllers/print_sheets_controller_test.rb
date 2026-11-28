# frozen_string_literal: true

require "test_helper"

class PrintSheetsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @unit = GeologicUnit.create!(
      macrostrat_id: 904_210,
      name: "Vashon Glacial Till",
      strat_name: "Fraser Drift",
      age: "Pleistocene",
      lithology: { "major" => "glacial clay, silt" }
    )

    @clay = UserSample.create!(
      title: "Nisqually Bluff Clay",
      material_category: :wild_clay,
      latitude: 47.0725,
      longitude: -122.7042,
      geologic_unit: @unit,
      notes: "Smooth plastic riverbank seam."
    )
    @clay.assay_results.create!(
      source_type: :spatial_heuristic_estimate,
      confidence_score: 0.78,
      oxides: {
        "SiO2" => 60.5,
        "Al2O3" => 18.2,
        "Fe2O3" => 5.1,
        "CaO" => 2.4,
        "MgO" => 1.3,
        "Na2O" => 1.1,
        "K2O" => 2.2,
        "TiO2" => 0.7,
        "P2O5" => 0.1,
        "MnO" => 0.1,
        "LOI" => 8.3
      },
      minor_oxides: { "BaO" => 2.6 },
      umf_formula: Chemistry::UmfCalculator.call(
        {
          "SiO2" => 60.5,
          "Al2O3" => 18.2,
          "Fe2O3" => 5.1,
          "CaO" => 2.4,
          "MgO" => 1.3,
          "Na2O" => 1.1,
          "K2O" => 2.2,
          "TiO2" => 0.7,
          "P2O5" => 0.1,
          "MnO" => 0.1,
          "LOI" => 8.3
        },
        minor_oxides: { "BaO" => 2.6 }
      )
    )
    @clay.field_observations.create!(
      vinegar_fizz: :slight,
      plasticity: :high_plastic,
      fired_cone: "6",
      drying_shrinkage_percent: 6.2,
      firing_shrinkage_percent: 5.4,
      boiling_water_absorption_percent: 2.1
    )

    @ash = UserSample.create!(
      title: "Alder Wood Ash",
      material_category: :wood_ash
    )
    @ash.assay_results.create!(
      source_type: :verified_lab_xrf,
      oxides: {
        "SiO2" => 12.0,
        "Al2O3" => 3.2,
        "Fe2O3" => 1.2,
        "CaO" => 52.0,
        "MgO" => 5.8,
        "Na2O" => 1.0,
        "K2O" => 6.2,
        "P2O5" => 2.6,
        "LOI" => 16.0
      }
    )
  end

  test "GET /samples/:id renders Print Kiln Bench Sheet button in Studio Export & Interoperability panel" do
    get sample_path(@clay)

    assert_response :success
    assert_includes response.body, "Print Kiln Bench Sheet"
    assert_includes response.body, print_sample_sheet_path(@clay)
  end

  test "GET /samples/:id/print renders printable sample bench sheet with QR SVG, stamp code, oxides, UMF, shrinkage worksheet, and hazard callouts" do
    get print_sample_sheet_path(@clay)

    assert_response :success
    assert_includes response.body, "DCI Tailor"
    assert_includes response.body, "Nisqually Bluff Clay"
    assert_includes response.body, format("DCIT-S%04d", @clay.id)
    assert_includes response.body, "Vashon Glacial Till"
    assert_includes response.body, "47.07250, -122.70420"
    assert_select ".qr-box svg", count: 1
    assert_includes response.body, "60.50"
    assert_includes response.body, "18.20"
    assert_includes response.body, "SiO₂ : Al₂O₃ Ratio"
    assert_includes response.body, "100 mm Shrinkage Bar"
    assert_includes response.body, "6.20%"
    assert_includes response.body, "2.10%"
    assert_includes response.body, "Barium Toxicity"
  end

  test "GET /blends/print renders 100g/500g/1000g/5000g scaled batch weights, QR SVG, UMF, COE, and test-cup checklist" do
    get print_blend_sheet_path, params: {
      sample_ids: [ @clay.id ],
      stock_keys: [ "whiting", "ferro_frit_3134" ],
      target_cone: "6",
      surface: "gloss",
      recipe_title: "Nisqually Studio Gloss"
    }

    assert_response :success
    assert_includes response.body, "DCI Tailor"
    assert_includes response.body, "Nisqually Studio Gloss"
    assert_includes response.body, format("DCIT-TX-S%04d-C6", @clay.id)
    assert_select ".qr-box svg", count: 1
    assert_includes response.body, "100 g Cup"
    assert_includes response.body, "500 g Pint"
    assert_includes response.body, "1,000 g (1 kg)"
    assert_includes response.body, "5,000 g Bucket"
    assert_includes response.body, "100.0 g"
    assert_includes response.body, "500.0 g"
    assert_includes response.body, "1000.0 g"
    assert_includes response.body, "5000.0 g"
    assert_includes response.body, "Nisqually Bluff Clay"
    assert_includes response.body, "Whiting (CaCO3)"
    assert_includes response.body, "Ferro Frit 3134"
    assert_includes response.body, "Predicted Optimal Seger UMF"
    assert_includes response.body, "×10⁻⁷ /°C"
    assert_includes response.body, "T01"
  end

  test "GET /blends/print returns 422 cleanly when fewer than 2 materials are provided" do
    get print_blend_sheet_path, params: { sample_ids: [ @clay.id ] }

    assert_response :unprocessable_content
    assert_includes response.body, "Unable to Generate Kiln Bench Sheet"
    assert_includes response.body, "Select 2 materials"
  end

  test "GET /blends renders triaxial [data-simplex-heatmap] SVG with 231 [data-simplex-point] circles and Print Kiln Bench Sheet button" do
    get blends_path, params: {
      sample_ids: [ @clay.id ],
      stock_keys: [ "whiting", "ferro_frit_3134" ],
      target_cone: "6",
      surface: "gloss"
    }

    assert_response :success
    assert_select "[data-simplex-heatmap]", count: 1
    assert_select "[data-simplex-heatmap] svg circle[data-simplex-point]", count: 231
    assert_select "[data-simplex-heatmap] svg circle[data-simplex-optimal='true']", count: 1
    assert_includes response.body, "Print Kiln Bench Sheet"
    assert_includes response.body, "/blends/print"
  end

  test "GET /blends renders 11 [data-line-tile] items in line-blend mode" do
    get blends_path, params: {
      sample_ids: [ @clay.id, @ash.id ],
      target_cone: "10",
      surface: "matte"
    }

    assert_response :success
    assert_select "[data-simplex-heatmap]", count: 1
    assert_select "[data-line-blend-strip] [data-line-tile]", count: 11
    assert_select "[data-line-blend-strip] [data-line-tile='T01']", count: 1
    assert_select "[data-line-blend-strip] [data-line-tile='T11']", count: 1
  end

  test "print endpoints enforce multi-user sample scoping and return 404 when foreign sample_ids are passed with stock modifiers" do
    other_user = User.create!(
      email: "other-potter@example.com",
      name: "Other Potter",
      password: "kiln-password-123",
      password_confirmation: "kiln-password-123"
    )
    private_sample = UserSample.create!(
      user: other_user,
      title: "Private Mountain Clay",
      material_category: :wild_clay
    )

    get print_sample_sheet_path(private_sample)
    assert_response :not_found

    get print_blend_sheet_path, params: {
      sample_ids: [ private_sample.id ],
      stock_keys: [ "whiting", "ferro_frit_3134" ],
      target_cone: "6",
      surface: "gloss"
    }
    assert_response :not_found

    get print_blend_sheet_path, params: {
      sample_ids: [ @clay.id, private_sample.id ],
      stock_keys: [ "whiting" ],
      target_cone: "6",
      surface: "gloss"
    }
    assert_response :not_found
  end

  test "GET /blends/print ignores injected script_name and host route options in back link and QR code" do
    clean_params = {
      sample_ids: [ @clay.id ],
      stock_keys: [ "whiting", "ferro_frit_3134" ],
      target_cone: "6",
      surface: "gloss",
      recipe_title: "Canonical Bench Glaze"
    }

    get print_blend_sheet_path, params: clean_params
    assert_response :success
    clean_back_href = css_select("header a").first["href"]
    clean_qr_markup = css_select(".qr-box").first.inner_html

    get print_blend_sheet_path, params: clean_params.merge(
      script_name: "//evil.example",
      host: "evil.example"
    )
    assert_response :success
    refute_includes response.body, "evil.example"
    assert_equal clean_back_href, css_select("header a").first["href"]
    assert_equal clean_qr_markup, css_select(".qr-box").first.inner_html
  end

  test "GET /blends and GET /blends/print do not double-escape titles containing ampersands and apostrophes" do
    @clay.update!(title: "Potter's Clay & Ash")

    get blends_path, params: {
      sample_ids: [ @clay.id, @ash.id ],
      target_cone: "10",
      surface: "matte"
    }
    assert_response :success
    refute_includes response.body, "&amp;amp;"
    refute_includes response.body, "&amp;#39;"

    get print_blend_sheet_path, params: {
      sample_ids: [ @clay.id, @ash.id ],
      target_cone: "10",
      surface: "matte"
    }
    assert_response :success
    refute_includes response.body, "&amp;amp;"
    refute_includes response.body, "&amp;#39;"
    refute_includes response.body, "<?xml"
  end
end
