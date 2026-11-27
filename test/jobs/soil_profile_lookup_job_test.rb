# frozen_string_literal: true

require "test_helper"

class SoilProfileLookupJobTest < ActiveJob::TestCase
  TACOMA_LAT = 47.2529
  TACOMA_LNG = -122.4443
  SDA_URL = "https://SDMDataAccess.sc.egov.usda.gov/Tabular/post.rest"

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
    assert_equal "555100", sample.soil_profile.mukey

    heuristic = sample.latest_heuristic_assay_result
    assert_not_nil heuristic
    assert heuristic.reasoning_log.any? { |line| line.include?("USDA SSURGO soil horizon prior") }
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

  test "returns nil gracefully for missing sample or sample without coordinates" do
    stub = stub_request(:post, SDA_URL)

    assert_nil SoilProfileLookupJob.perform_now(-999_999)

    sample = UserSample.create!(title: "No GPS Clay", material_category: :wild_clay)
    assert_nil SoilProfileLookupJob.perform_now(sample.id)
    assert_nil sample.reload.soil_profile_id
    assert_not_requested stub
  end
end
