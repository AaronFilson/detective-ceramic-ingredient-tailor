# frozen_string_literal: true

require "test_helper"

class SoilProfileLookupJobTest < ActiveJob::TestCase
  TACOMA_LAT = 47.2529
  TACOMA_LNG = -122.4443
  MASHIKO_LAT = 36.4650
  MASHIKO_LNG = 140.0960
  SDA_URL = "https://SDMDataAccess.sc.egov.usda.gov/Tabular/post.rest"
  SOILGRIDS_URL = "https://rest.isric.org/soilgrids/v2.0/properties/query"

  setup do
    WebMock.reset!
    SoilProfile.delete_all
  end

  test "attaches fetched SoilProfile to UserSample and refreshes heuristic estimate when no verified lab assay exists" do
    sda_body = {
      Table: [
        [ "555100", "Kitsap silt loam", "Kitsap", "85", "Bt", "30", "90", "42.0", "22.0", "5.0" ]
      ]
    }.to_json

    stub_request(:post, SDA_URL)
      .to_return(status: 200, body: sda_body, headers: { "Content-Type" => "application/json" })
    soilgrids_stub = stub_request(:get, /#{Regexp.escape(SOILGRIDS_URL)}/)

    sample = UserSample.create!(
      title: "Tacoma Backyard Wild Clay",
      material_category: :wild_clay,
      latitude: TACOMA_LAT,
      longitude: TACOMA_LNG
    )
    assert_nil sample.soil_profile_id

    profile = SoilProfileLookupJob.perform_now(sample.id)

    sample.reload
    assert_not_nil profile
    assert_equal profile.id, sample.soil_profile_id
    assert_equal "usda_ssurgo", sample.soil_profile.source
    assert_equal "555100", sample.soil_profile.mukey
    assert_not_requested soilgrids_stub

    heuristic = sample.latest_heuristic_assay_result
    assert_not_nil heuristic
    assert heuristic.reasoning_log.any? { |line| line.include?("USDA SSURGO soil horizon prior") }
  end

  test "falls back automatically to ISRIC SoilGrids v2 for non-US coordinates when USDA SSURGO returns nil" do
    ssurgo_stub = stub_request(:post, SDA_URL)
      .to_return(status: 200, body: { Table: [] }.to_json, headers: { "Content-Type" => "application/json" })

    soilgrids_body = {
      type: "Feature",
      geometry: { type: "Point", coordinates: [ MASHIKO_LNG, MASHIKO_LAT ] },
      properties: {
        layers: [
          {
            name: "clay",
            depths: [
              { label: "0-5cm", range: { top_depth: 0, bottom_depth: 5 }, values: { mean: 260 } },
              { label: "30-60cm", range: { top_depth: 30, bottom_depth: 60 }, values: { mean: 390 } }
            ]
          },
          {
            name: "silt",
            depths: [
              { label: "0-5cm", range: { top_depth: 0, bottom_depth: 5 }, values: { mean: 430 } },
              { label: "30-60cm", range: { top_depth: 30, bottom_depth: 60 }, values: { mean: 410 } }
            ]
          },
          {
            name: "sand",
            depths: [
              { label: "0-5cm", range: { top_depth: 0, bottom_depth: 5 }, values: { mean: 310 } },
              { label: "30-60cm", range: { top_depth: 30, bottom_depth: 60 }, values: { mean: 200 } }
            ]
          },
          {
            name: "phh2o",
            depths: [
              { label: "0-5cm", range: { top_depth: 0, bottom_depth: 5 }, values: { mean: 56 } },
              { label: "30-60cm", range: { top_depth: 30, bottom_depth: 60 }, values: { mean: 58 } }
            ]
          },
          {
            name: "cec",
            depths: [
              { label: "0-5cm", range: { top_depth: 0, bottom_depth: 5 }, values: { mean: 190 } },
              { label: "30-60cm", range: { top_depth: 30, bottom_depth: 60 }, values: { mean: 215 } }
            ]
          },
          {
            name: "soc",
            depths: [
              { label: "0-5cm", range: { top_depth: 0, bottom_depth: 5 }, values: { mean: 280 } },
              { label: "30-60cm", range: { top_depth: 30, bottom_depth: 60 }, values: { mean: 95 } }
            ]
          }
        ]
      }
    }.to_json

    soilgrids_stub = stub_request(:get, /#{Regexp.escape(SOILGRIDS_URL)}/)
      .to_return(status: 200, body: soilgrids_body, headers: { "Content-Type" => "application/json" })

    sample = UserSample.create!(
      title: "Mashiko Tochigi Wild Clay",
      material_category: :wild_clay,
      latitude: MASHIKO_LAT,
      longitude: MASHIKO_LNG
    )

    profile = SoilProfileLookupJob.perform_now(sample.id)

    assert_requested ssurgo_stub, times: 1
    assert_requested soilgrids_stub, times: 1
    assert_not_nil profile
    assert_equal "isric_soilgrids", profile.source
    assert_equal "soilgrids:36.465:140.096", profile.mukey
    assert_equal "Silty Clay Loam", profile.component_name
    assert_in_delta 39.0, profile.max_clay_pct.to_f, 0.01
    assert_in_delta 5.8, profile.soil_ph.to_f, 0.01
    assert_in_delta 21.5, profile.cec.to_f, 0.01

    sample.reload
    assert_equal profile.id, sample.soil_profile_id
    assert_not_nil sample.latest_heuristic_assay_result
  end

  test "attaches SoilProfile without overwriting or triggering heuristic refresh when verified lab assay exists" do
    sda_body = {
      Table: [
        [ "555200", "Alderwood gravelly sandy loam", "Alderwood", "85", "Bt", "35", "80", "40.0", "18.0", "4.0" ]
      ]
    }.to_json

    stub_request(:post, SDA_URL)
      .to_return(status: 200, body: sda_body, headers: { "Content-Type" => "application/json" })

    sample = UserSample.create!(
      title: "Lab Verified Wild Clay",
      material_category: :wild_clay,
      latitude: TACOMA_LAT,
      longitude: TACOMA_LNG
    )
    sample.assay_results.create!(
      source_type: :verified_lab_xrf,
      oxides: {
        "SiO2" => 60.0, "Al2O3" => 18.0, "Fe2O3" => 5.0, "CaO" => 2.5,
        "MgO" => 2.0, "Na2O" => 1.5, "K2O" => 2.5, "TiO2" => 0.8,
        "P2O5" => 0.1, "MnO" => 0.1, "LOI" => 7.5
      },
      confidence_score: 0.98,
      reasoning_log: [ "Verified lab XRF" ]
    )

    SoilProfileLookupJob.perform_now(sample.id)

    sample.reload
    assert_equal "555200", sample.soil_profile.mukey
    assert_nil sample.latest_heuristic_assay_result
  end

  test "returns nil gracefully for missing sample, sample without coordinates, or dual API miss" do
    stub = stub_request(:post, SDA_URL)
    sg_stub = stub_request(:get, /#{Regexp.escape(SOILGRIDS_URL)}/)

    assert_nil SoilProfileLookupJob.perform_now(-999_999)

    sample = UserSample.create!(title: "No GPS Clay", material_category: :wild_clay)
    assert_nil SoilProfileLookupJob.perform_now(sample.id)
    assert_nil sample.reload.soil_profile_id
    assert_not_requested stub
    assert_not_requested sg_stub

    # When both USDA SSURGO and ISRIC SoilGrids return empty/nil
    stub_request(:post, SDA_URL)
      .to_return(status: 200, body: { Table: [] }.to_json, headers: { "Content-Type" => "application/json" })
    stub_request(:get, /#{Regexp.escape(SOILGRIDS_URL)}/)
      .to_return(status: 200, body: { properties: { layers: [] } }.to_json, headers: { "Content-Type" => "application/json" })

    ocean_sample = UserSample.create!(title: "Mid-Ocean Pin", material_category: :wild_clay, latitude: 10.0, longitude: -150.0)
    assert_nil SoilProfileLookupJob.perform_now(ocean_sample.id)
    assert_nil ocean_sample.reload.soil_profile_id
  end

  test "renders upgraded _soil_profile_card partial for SoilGrids, CEC mineralogy hints, and USGS DS-801 XRD bar" do
    soilgrids_profile = SoilProfile.create!(
      source: "isric_soilgrids",
      mukey: "soilgrids:50.340:-4.790",
      map_unit_name: "ISRIC SoilGrids v2 (250m Global)",
      component_name: "Silty Clay",
      max_clay_pct: 44.0,
      soil_ph: 5.2,
      cec: 52.0,
      organic_carbon: 14.5,
      latitude: 50.34,
      longitude: -4.79,
      horizons: [
        { "hzname" => "D1", "top_cm" => 0, "bottom_cm" => 5, "clay_pct" => 32.0, "silt_pct" => 44.0, "sand_pct" => 24.0, "ph" => 5.4, "cec_cmol_kg" => 41.0, "soc_g_kg" => 28.0 },
        { "hzname" => "D4", "top_cm" => 30, "bottom_cm" => 60, "clay_pct" => 44.0, "silt_pct" => 42.0, "sand_pct" => 14.0, "ph" => 5.2, "cec_cmol_kg" => 52.0, "soc_g_kg" => 14.5 }
      ]
    )

    xrd_assay = ReferenceAssay.create!(
      source: "usgs_ds801",
      external_id: "DS801-CARD-TEST-C",
      rock_type: "kaolin_clay",
      sample_media: "soil_c_horizon",
      latitude: 47.258,
      longitude: -122.452,
      oxides: {
        "SiO2" => 58.0, "Al2O3" => 24.0, "Fe2O3" => 3.5, "CaO" => 1.0,
        "MgO" => 1.0, "Na2O" => 1.0, "K2O" => 2.5, "TiO2" => 0.8,
        "P2O5" => 0.1, "MnO" => 0.1, "LOI" => 8.0
      },
      xrd_mineralogy: {
        "quartz" => 30.0,
        "kaolinite" => 36.0,
        "illite" => 14.0,
        "smectite" => 8.0,
        "k_feldspar" => 6.0,
        "plagioclase" => 4.0,
        "calcite" => 2.0
      }
    )

    html = ApplicationController.render(
      partial: "samples/soil_profile_card",
      locals: { soil_profile: soilgrids_profile, nearby_xrd_assays: [ xrd_assay ] }
    )

    assert_includes html, "ISRIC SoilGrids v2 (Global 250m)"
    assert_includes html, "Silty Clay"
    assert_includes html, "pH"
    assert_includes html, "5.2"
    assert_includes html, "52 cmol/kg"
    assert_includes html, "Smectitic"
    assert_includes html, "14.5 g/kg"
    assert_includes html, "Regional Soil XRD Mineralogy (USGS DS-801)"
    assert_includes html, "Quartz"
    assert_includes html, "Kaolinite"
    assert_includes html, "Illite"
    assert_includes html, "Smectite"
    assert_includes html, "Feldspar"
    assert_includes html, "Calcite"

    # Kaolinitic (< 15 cmol/kg) hint and backwards-compatible call omitting nearby_xrd_assays
    soilgrids_profile.update!(cec: 10.5)
    kaolin_html = ApplicationController.render(
      partial: "samples/soil_profile_card",
      locals: { soil_profile: soilgrids_profile }
    )
    assert_includes kaolin_html, "Kaolinitic"
    assert_not_includes kaolin_html, "Regional Soil XRD Mineralogy"

    # USDA NRCS SSURGO badge check
    ssurgo_profile = SoilProfile.create!(
      source: "usda_ssurgo",
      mukey: "468120",
      map_unit_name: "Alderwood gravelly sandy loam",
      component_name: "Alderwood",
      component_percent: 85,
      max_clay_pct: 42.0,
      cec: 22.0,
      latitude: TACOMA_LAT,
      longitude: TACOMA_LNG,
      horizons: [
        { "hzname" => "Bt", "top_cm" => 35, "bottom_cm" => 90, "clay_pct" => 42.0, "plasticity_index" => 24.0, "caco3_pct" => 0.0 }
      ]
    )
    ssurgo_html = ApplicationController.render(
      partial: "samples/soil_profile_card",
      locals: { soil_profile: ssurgo_profile }
    )
    assert_includes ssurgo_html, "USDA NRCS SSURGO"
    assert_includes ssurgo_html, "MUKEY #468120"
    assert_includes ssurgo_html, "Illitic"
  end
end
