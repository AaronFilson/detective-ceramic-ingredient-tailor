# frozen_string_literal: true

require "test_helper"

module Clients
  class UsdaSsurgoClientTest < ActiveSupport::TestCase
    TACOMA_LAT = 47.2529
    TACOMA_LNG = -122.4443
    SDA_URL = "https://SDMDataAccess.sc.egov.usda.gov/Tabular/post.rest"

    setup do
      WebMock.reset!
      SoilProfile.delete_all
    end

    test "queries SDA Tabular REST API, selects dominant component, parses horizons, and persists SoilProfile" do
      sda_body = {
        Table: [
          # Minor component (15%) should NOT be selected
          [ "456789", "Alderwood-Everett complex, 8 to 15 percent slopes", "Everett", "15", "A", "0", "18", "8.0", "2.0", "0.0" ],
          [ "456789", "Alderwood-Everett complex, 8 to 15 percent slopes", "Everett", "15", "Bw", "18", "75", "10.0", "4.0", "0.0" ],
          # Dominant component (80%) with clay-rich Bt horizon and calcareous Ck horizon
          [ "456789", "Alderwood-Everett complex, 8 to 15 percent slopes", "Alderwood", "80", "Bt", "30", "85", "42.5", "24.0", "1.0" ],
          [ "456789", "Alderwood-Everett complex, 8 to 15 percent slopes", "Alderwood", "80", "A", "0", "30", "18.0", "8.5", "0.0" ],
          [ "456789", "Alderwood-Everett complex, 8 to 15 percent slopes", "Alderwood", "80", "Ck", "85", "150", "31.0", "15.0", "6.5" ]
        ]
      }.to_json

      stub = stub_request(:post, SDA_URL)
        .with do |req|
          parsed = JSON.parse(req.body)
          parsed["format"] == "JSON" &&
            parsed["query"].include?("SDA_Get_Mukey_from_intersection_with_WktWgs84('point(-122.444300 47.252900)')") &&
            parsed["query"].include?("chorizon")
        end
        .to_return(status: 200, body: sda_body, headers: { "Content-Type" => "application/json" })

      profile = Clients::UsdaSsurgoClient.lookup(lat: TACOMA_LAT, lng: TACOMA_LNG)

      assert_requested stub, times: 1
      assert_kind_of SoilProfile, profile
      assert profile.persisted?
      assert_equal "456789", profile.mukey
      assert_equal "Alderwood-Everett complex, 8 to 15 percent slopes", profile.map_unit_name
      assert_equal "Alderwood", profile.component_name
      assert_in_delta 80.0, profile.component_percent.to_f, 0.01
      assert_in_delta 42.5, profile.max_clay_pct.to_f, 0.01
      assert_in_delta 24.0, profile.max_plasticity_index.to_f, 0.01
      assert_in_delta 6.5, profile.max_caco3_pct.to_f, 0.01
      assert_not_nil profile.fetched_at
      assert_in_delta TACOMA_LAT, profile.latitude, 0.0001
      assert_in_delta TACOMA_LNG, profile.longitude, 0.0001

      # Horizons sorted by top_cm ASC and exclude minor component Everett
      assert_equal 3, profile.horizons.size
      assert_equal %w[A Bt Ck], profile.horizons.map { |h| h["hzname"] }
      assert_equal 0, profile.horizons.first["top_cm"]
      assert_equal 30, profile.horizons.first["bottom_cm"]
      assert_equal "Bt", profile.clay_rich_horizon["hzname"]
      assert_includes profile.summary_label, "Alderwood"
      assert_includes profile.summary_label, "43% clay"
    end

    test "returns cached SoilProfile within 250m without making HTTP request" do
      cached = SoilProfile.create!(
        mukey: "777001",
        map_unit_name: "Kitsap silt loam",
        component_name: "Kitsap",
        component_percent: 85,
        horizons: [
          { "hzname" => "Bt", "top_cm" => 35, "bottom_cm" => 90, "clay_pct" => 38.0, "plasticity_index" => 20.0, "caco3_pct" => 0.0 }
        ],
        max_clay_pct: 38.0,
        max_plasticity_index: 20.0,
        max_caco3_pct: 0.0,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG,
        fetched_at: 1.hour.ago
      )

      stub = stub_request(:post, SDA_URL)

      # ~111m north of cached point (within 250m radius)
      result = Clients::UsdaSsurgoClient.lookup(lat: TACOMA_LAT + 0.001, lng: TACOMA_LNG)

      assert_equal cached.id, result.id
      assert_not_requested stub
    end

    test "force_refresh bypasses 250m cache and upserts existing mukey idempotently" do
      existing = SoilProfile.create!(
        mukey: "777002",
        map_unit_name: "Old Name",
        component_name: "OldComp",
        component_percent: 60,
        horizons: [],
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG,
        fetched_at: 2.days.ago
      )

      refreshed_body = {
        Table: [
          [ "777002", "Kitsap silt loam, 2 to 8 percent slopes", "Kitsap", "90", "Bt1", "25", "70", "44.0", "26.5", "0.5" ]
        ]
      }.to_json

      stub = stub_request(:post, SDA_URL)
        .to_return(status: 200, body: refreshed_body, headers: { "Content-Type" => "application/json" })

      result = Clients::UsdaSsurgoClient.lookup(lat: TACOMA_LAT, lng: TACOMA_LNG, force_refresh: true)

      assert_requested stub, times: 1
      assert_equal existing.id, result.id
      assert_equal "Kitsap", result.reload.component_name
      assert_in_delta 44.0, result.max_clay_pct.to_f, 0.01
      assert_equal 1, SoilProfile.where(mukey: "777002").count
    end

    test "retries on 503, 429, and network timeout before succeeding" do
      success_body = {
        Table: [
          [ "888001", "Puyallup fine sandy loam", "Puyallup", "85", "B", "20", "65", "22.0", "10.0", "0.0" ]
        ]
      }.to_json

      stub = stub_request(:post, SDA_URL)
        .to_return(
          { status: 503, body: "Service Unavailable" },
          { status: 429, body: "Too Many Requests" },
          { status: 200, body: success_body }
        )

      profile = Clients::UsdaSsurgoClient.new(retry_delay: 0.0).lookup(lat: 47.185, lng: -122.293)

      assert_requested stub, times: 3
      assert_equal "888001", profile.mukey
      assert_equal "Puyallup", profile.component_name

      WebMock.reset!
      timeout_stub = stub_request(:post, SDA_URL)
        .to_timeout
        .then
        .to_return(status: 200, body: success_body)

      recovered = Clients::UsdaSsurgoClient.new(retry_delay: 0.0).lookup(lat: 47.40, lng: -122.20)
      assert_requested timeout_stub, times: 2
      assert_equal "888001", recovered.mukey
    end

    test "lookup returns nil gracefully offline or on empty Table while lookup! raises Error on failure" do
      stub = stub_request(:post, SDA_URL).to_timeout

      assert_nil Clients::UsdaSsurgoClient.new(retry_delay: 0.0).lookup(lat: 47.0, lng: -122.0)
      assert_requested stub, times: 3

      assert_raises(Clients::UsdaSsurgoClient::NetworkError) do
        Clients::UsdaSsurgoClient.new(retry_delay: 0.0).lookup!(lat: 47.0, lng: -122.0)
      end

      WebMock.reset!
      stub_request(:post, SDA_URL).to_return(status: 200, body: { Table: [] }.to_json)

      assert_nil Clients::UsdaSsurgoClient.lookup(lat: 0.0, lng: 0.0)
      assert_nil Clients::UsdaSsurgoClient.lookup!(lat: 0.0, lng: 0.0)
    end

    test "rejects invalid or SQL-injection coordinates before making any HTTP call" do
      stub = stub_request(:post, SDA_URL)

      assert_nil Clients::UsdaSsurgoClient.lookup(lat: nil, lng: -122.4)
      assert_nil Clients::UsdaSsurgoClient.lookup(lat: 91.0, lng: -122.4)
      assert_nil Clients::UsdaSsurgoClient.lookup(lat: 47.2, lng: -181.0)
      assert_nil Clients::UsdaSsurgoClient.lookup(lat: "47.2'; DROP TABLE mapunit;--", lng: -122.4)

      assert_raises(Clients::UsdaSsurgoClient::Error) do
        Clients::UsdaSsurgoClient.lookup!(lat: "47.2' OR 1=1--", lng: -122.4)
      end

      assert_not_requested stub
    end
  end
end
