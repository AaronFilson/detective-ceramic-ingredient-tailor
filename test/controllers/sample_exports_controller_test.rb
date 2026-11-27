# frozen_string_literal: true

require "test_helper"

class SampleExportsControllerTest < ActionDispatch::IntegrationTest
  MOLAR_MASSES = Exporters::GlazecalcMaterialSerializer::MOLAR_MASSES

  setup do
    @unit = GeologicUnit.create!(
      macrostrat_id: 90303,
      name: "Vashon Glacial Drift",
      strat_name: "Puget Lobe Till",
      age: "Pleistocene",
      lithology: { "major" => [ "clay", "silt" ] }
    )

    @sample = UserSample.create!(
      title: "Tacoma Clay #1 (North Bluff)",
      material_category: :wild_clay,
      geologic_unit: @unit,
      latitude: 47.2529,
      longitude: -122.4443,
      notes: "Found along shoreline exposure"
    )

    @sample.field_observations.create!(
      vinegar_fizz: :vigorous,
      plasticity: :high_plastic,
      fired_cone: "6",
      fired_color: "red brown",
      shrinkage_percent: 12.25
    )

    @assay = @sample.assay_results.create!(
      source_type: :spatial_heuristic_estimate,
      confidence_score: 0.84,
      oxides: {
        "SiO2" => 57.45,
        "Al2O3" => 16.35,
        "Fe2O3" => 5.20,
        "CaO" => 6.40,
        "MgO" => 2.15,
        "Na2O" => 1.05,
        "K2O" => 1.55,
        "TiO2" => 0.75,
        "LOI" => 9.10
      },
      oxide_ranges: {
        "CaO" => { "min" => 3.5, "median" => 6.4, "max" => 9.2 }
      },
      reasoning_log: [ "Vigorous vinegar fizz shifted CaO and LOI upward" ]
    )
  end

  test "GET /samples/:id/export/glazecalc.json meets Acceptance Criterion 4 chemistry and schema checks" do
    get "/samples/#{@sample.id}/export/glazecalc.json"

    assert_response :success
    assert_includes response.media_type, "application/json"
    assert_nil response.headers["Content-Disposition"]

    body = JSON.parse(response.body)
    assert_equal "Tacoma Clay #1 (North Bluff)", body["name"]
    assert_equal "percent", body["percentmole"]
    assert_equal 100.0, body["molecularweight"]
    assert body["loi"] >= 0.0 && body["loi"] < 100.0

    # Acceptance Criterion #4: oxideAnalysis + loi == 100.0% (+/- 0.1%)
    oxide_sum = body["oxideAnalysis"].values.sum + body["loi"]
    assert_in_delta 100.0, oxide_sum, 0.1

    # fields[].amount + loi == 100.0% (+/- 0.1%) and no LOI in fields
    assert_not_includes body["fields"].map { |f| f["name"] }, "LOI"
    fields_sum = body["fields"].sum { |f| f["amount"].to_f } + body["loi"]
    assert_in_delta 100.0, fields_sum, 0.1

    # amountUnity agrees with (wt_pct / 100 / molar_mass) * equivalent within 1%
    body["fields"].each do |field|
      oxide = field["name"]
      wt_pct = field["amount"].to_f
      expected_unity = (wt_pct / 100.0 / MOLAR_MASSES.fetch(oxide)) * body["equivalent"]
      assert_in_delta expected_unity, field["amountUnity"], expected_unity * 0.01,
        "amountUnity drift > 1% for #{oxide}"
    end
  end

  test "GET /samples/:id/export/glazecalc.json?download=1 sets attachment Content-Disposition" do
    get "/samples/#{@sample.id}/export/glazecalc.json", params: { download: "1" }

    assert_response :success
    assert_equal(
      'attachment; filename="tacoma-clay-1-north-bluff-glazecalc.json"',
      response.headers["Content-Disposition"]
    )
  end

  test "GET /samples/:id/export/glaze_vault.json returns valid glaze-vault-export v1 archive" do
    get "/samples/#{@sample.id}/export/glaze_vault.json"

    assert_response :success
    assert_includes response.media_type, "application/json"
    assert_equal(
      'inline; filename="tacoma-clay-1-north-bluff-glaze-vault.json"',
      response.headers["Content-Disposition"]
    )

    body = JSON.parse(response.body)
    assert_equal "glaze-vault-export", body["format"]
    assert_equal 1, body["version"]
    assert_equal 1, body["materials"].length

    material = body["materials"].first
    assert_equal "Tacoma Clay #1 (North Bluff)", material["name"]
    assert_includes Exporters::GlazeVaultSerializer::MATERIAL_CLASSES, material["class"]
    assert_equal "9.10", material["loi"]
    assert_equal({ "cone" => "6", "totalShrinkage" => "12.25" }, material["sheet"])

    total = material["oxides"].sum { |o| o["percent"].to_f } + material["loi"].to_f
    assert_in_delta 100.0, total, 0.1

    provenance = body["provenance"]
    assert_in_delta 47.2529, provenance["sample"]["latitude"], 0.0001
    assert_equal 90303, provenance["geologic_unit"]["macrostrat_id"]
    assert_equal 1, provenance["field_observations"].length
    assert_equal 6.4, provenance["assay_result"]["oxide_ranges"]["CaO"]["median"]
    assert_not_nil provenance["assay_result"]["umf_formula"]["fluxes"]
  end

  test "GET /samples/:id/export/glaze_vault.json?download=1 sets attachment header" do
    get "/samples/#{@sample.id}/export/glaze_vault.json", params: { download: "1" }

    assert_response :success
    assert_equal(
      'attachment; filename="tacoma-clay-1-north-bluff-glaze-vault.json"',
      response.headers["Content-Disposition"]
    )
  end

  test "returns 404 JSON when sample or assay result is missing" do
    get "/samples/999999999/export/glazecalc.json"
    assert_response :not_found
    assert JSON.parse(response.body)["error"].present?

    sample_without_assay = UserSample.create!(title: "No Assay Yet")
    get "/samples/#{sample_without_assay.id}/export/glazecalc.json"
    assert_response :not_found
    assert_includes JSON.parse(response.body)["error"], "No assay result"

    get "/samples/#{sample_without_assay.id}/export/glaze_vault.json"
    assert_response :not_found
    assert_includes JSON.parse(response.body)["error"], "No assay result"
  end

  test "returns 422 JSON when assay result has empty oxides" do
    sample = UserSample.create!(title: "Empty Oxide Assay")
    sample.assay_results.create!(oxides: {})

    get "/samples/#{sample.id}/export/glazecalc.json"
    assert_response :unprocessable_content
    assert JSON.parse(response.body)["error"].present?
  end

  test "allows non-browser API clients on JSON export endpoints" do
    get "/samples/#{@sample.id}/export/glazecalc.json",
      headers: { "User-Agent" => "Mozilla/4.0 (compatible; MSIE 6.0; Windows NT 5.1)" }

    assert_response :success
    assert_includes response.media_type, "application/json"

    get "/samples/#{@sample.id}/export/glazecalc"
    assert_response :success
    assert_includes response.media_type, "application/json"
  end
end
