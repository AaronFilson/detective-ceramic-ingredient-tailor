# frozen_string_literal: true

require "test_helper"

class MineralOccurrenceLookupJobTest < ActiveJob::TestCase
  TACOMA_LAT = 47.2529
  TACOMA_LNG = -122.4443
  MRDS_URL = "https://mrdata.usgs.gov/services/mrds"
  MINDAT_URL = "https://api.mindat.org/localities/"

  setup do
    WebMock.reset!
    MineralOccurrence.delete_all
    @prev_mindat_token = ENV["MINDAT_API_TOKEN"]
  end

  teardown do
    ENV["MINDAT_API_TOKEN"] = @prev_mindat_token
  end

  test "runs USGS MRDS lookup and skips Mindat when MINDAT_API_TOKEN is blank" do
    ENV["MINDAT_API_TOKEN"] = nil

    mrds_stub = stub_request(:get, MRDS_URL)
      .with(query: hash_including("service" => "WFS", "typeName" => "mrds"))
      .to_return(
        status: 200,
        body: {
          type: "FeatureCollection",
          features: [
            {
              type: "Feature",
              geometry: { type: "Point", coordinates: [ -121.9915, 47.2043 ] },
              properties: {
                dep_id: "88001",
                site_name: "Enumclaw MRDS Iron-Silica Quarry",
                commod1: "Iron",
                commod2: "Silica",
                dep_type: "Volcanic Flow"
              }
            }
          ]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    mindat_stub = stub_request(:get, /api\.mindat\.org/)

    results = MineralOccurrenceLookupJob.perform_now(TACOMA_LAT, TACOMA_LNG, radius_km: 50)

    assert_requested mrds_stub, times: 1
    assert_not_requested mindat_stub
    assert_equal 1, results.size
    assert_equal "usgs_mrds", results.first.source
    assert_equal "88001", results.first.external_id
  end

  test "runs both USGS MRDS and Mindat lookups when MINDAT_API_TOKEN is configured" do
    ENV["MINDAT_API_TOKEN"] = "job-test-token"

    mrds_stub = stub_request(:get, MRDS_URL)
      .with(query: hash_including("service" => "WFS", "typeName" => "mrds"))
      .to_return(
        status: 200,
        body: {
          type: "FeatureCollection",
          features: [
            {
              type: "Feature",
              geometry: { type: "Point", coordinates: [ -121.99, 47.20 ] },
              properties: {
                dep_id: "88002",
                site_name: "Cascade Talc Prospect",
                commod1: "Talc"
              }
            }
          ]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    mindat_stub = stub_request(:get, MINDAT_URL)
      .with(
        headers: { "Authorization" => "Token job-test-token" },
        query: hash_including("lat_min", "lat_max", "lon_min", "lon_max")
      )
      .to_return(
        status: 200,
        body: {
          results: [
            {
              id: 99001,
              txt: "Cascade Mindat Pegmatite",
              latitude: 47.25,
              longitude: -122.10,
              minerals: [ "Microcline", "Quartz" ],
              loc_type: "Pegmatite"
            }
          ]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    results = MineralOccurrenceLookupJob.perform_now(TACOMA_LAT, TACOMA_LNG, radius_km: 50)

    assert_requested mrds_stub, times: 1
    assert_requested mindat_stub, times: 1
    assert_equal 2, results.size
    assert_equal %w[mindat usgs_mrds], results.map(&:source).sort
  end

  test "returns empty array gracefully when coordinates are missing" do
    stub = stub_request(:get, /mrdata\.usgs\.gov|api\.mindat\.org/)

    assert_equal [], MineralOccurrenceLookupJob.perform_now(nil, -122.4443)
    assert_equal [], MineralOccurrenceLookupJob.perform_now(47.2529, "")
    assert_not_requested stub
  end
end
