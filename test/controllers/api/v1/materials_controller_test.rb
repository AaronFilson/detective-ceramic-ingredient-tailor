# frozen_string_literal: true

require "test_helper"

class Api::V1::MaterialsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @unit = GeologicUnit.create!(
      macrostrat_id: 90404,
      name: "Cascade Granodiorite",
      strat_name: "Snoqualmie Batholith",
      age: "Miocene",
      lithology: { "major" => [ "granodiorite", "granite" ] }
    )

    @sample = UserSample.create!(
      title: "Snoqualmie Crushed Feldspar",
      material_category: :crushed_rock,
      geologic_unit: @unit,
      latitude: 47.4204,
      longitude: -121.4139,
      notes: "Crushed and ball-milled 200 mesh"
    )

    @older_assay = @sample.assay_results.create!(
      source_type: :spatial_heuristic_estimate,
      confidence_score: 0.65,
      oxides: { "SiO2" => 65.0, "Al2O3" => 17.0, "K2O" => 10.0, "Na2O" => 6.0, "LOI" => 2.0 },
      created_at: 2.hours.ago
    )

    @latest_assay = @sample.assay_results.create!(
      source_type: :verified_lab_xrf,
      confidence_score: 0.98,
      oxides: {
        "SiO2" => 67.8,
        "Al2O3" => 18.1,
        "Fe2O3" => 0.4,
        "CaO" => 1.1,
        "MgO" => 0.2,
        "Na2O" => 3.5,
        "K2O" => 8.4,
        "LOI" => 0.5
      },
      reasoning_log: [ "Verified XRF lab analysis uploaded" ]
    )
  end

  test "GET /api/v1/materials/:id returns 200 JSON with glazecalc fields, api_version, and links" do
    get "/api/v1/materials/#{@sample.id}"

    assert_response :success
    assert_includes response.media_type, "application/json"

    body = JSON.parse(response.body)
    assert_equal "v1", body["api_version"]
    assert_equal "Snoqualmie Crushed Feldspar", body["name"]
    assert_equal "percent", body["percentmole"]
    assert_equal 100.0, body["molecularweight"]
    assert_equal 0.5, body["loi"]
    assert_equal @latest_assay.id, body["source"]["assay_result_id"]
    assert_equal "verified_lab_xrf", body["source"]["kind"]
    assert_in_delta 100.0, body["oxideAnalysis"].values.sum + body["loi"], 0.01

    assert_includes body["links"]["self"], "/api/v1/materials/#{@sample.id}"
    assert_includes body["links"]["glazecalc_export"], "/samples/#{@sample.id}/export/glazecalc.json"
    assert_includes body["links"]["glaze_vault_export"], "/samples/#{@sample.id}/export/glaze_vault.json"
  end

  test "GET /api/v1/materials/:id returns 404 JSON when sample, assay, or oxides are missing" do
    get "/api/v1/materials/999999999"
    assert_response :not_found
    assert_equal "Material not found", JSON.parse(response.body)["error"]

    no_assay_sample = UserSample.create!(title: "Pending Sample")
    get "/api/v1/materials/#{no_assay_sample.id}"
    assert_response :not_found
    assert_includes JSON.parse(response.body)["error"], "No assay result"

    no_assay_sample.assay_results.create!(oxides: {})
    get "/api/v1/materials/#{no_assay_sample.id}"
    assert_response :not_found
    assert JSON.parse(response.body)["error"].present?
  end

  test "GET /api/v1/materials lists only exportable materials with links" do
    second_sample = UserSample.create!(title: "Puget Sound Silt", material_category: :wild_clay)
    second_sample.assay_results.create!(
      oxides: { "SiO2" => 61.0, "Al2O3" => 18.0, "Fe2O3" => 5.0, "CaO" => 4.0, "K2O" => 2.0, "LOI" => 10.0 }
    )

    # Should be excluded from index (no assay / empty oxides)
    UserSample.create!(title: "Unanalyzed Clay")
    empty_sample = UserSample.create!(title: "Broken Assay")
    empty_sample.assay_results.create!(oxides: {})

    get "/api/v1/materials"

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "v1", body["api_version"]
    assert_equal 2, body["count"]

    names = body["materials"].map { |m| m["name"] }
    assert_includes names, "Snoqualmie Crushed Feldspar"
    assert_includes names, "Puget Sound Silt"
    assert_not_includes names, "Unanalyzed Clay"
    assert_not_includes names, "Broken Assay"

    body["materials"].each do |material|
      assert material["links"]["glazecalc_export"].present?
      assert material["links"]["glaze_vault_export"].present?
      assert_in_delta 100.0, material["oxideAnalysis"].values.sum + material["loi"], 0.01
    end
  end
end
