# frozen_string_literal: true

require "test_helper"

module Clients
  class MindatClientTest < ActiveSupport::TestCase
    TACOMA_LAT = 47.2529
    TACOMA_LNG = -122.4443
    MINDAT_URL = "https://api.mindat.org/localities/"
    TEST_TOKEN = "test-mindat-secret-token"

    setup do
      WebMock.reset!
      MineralOccurrence.delete_all
    end

    test "configured? checks whether api token is present" do
      assert Clients::MindatClient.configured?("abc123")
      assert_not Clients::MindatClient.configured?("")
      assert_not Clients::MindatClient.configured?("   ")
      assert_not Clients::MindatClient.configured?(nil)
    end

    test "skips gracefully and returns empty array without HTTP request when api_token is blank" do
      stub = stub_request(:get, /api\.mindat\.org/)

      assert_equal [], Clients::MindatClient.search_nearby(
        lat: TACOMA_LAT,
        lng: TACOMA_LNG,
        api_token: nil
      )
      assert_equal [], Clients::MindatClient.search_nearby(
        lat: TACOMA_LAT,
        lng: TACOMA_LNG,
        api_token: "   "
      )
      assert_not_requested stub
    end

    test "queries Mindat paginated API with Token auth and bbox, parses localities, and persists occurrences" do
      page1_body = {
        count: 2,
        next: "https://api.mindat.org/localities/?page=2&lat_min=46.80376",
        previous: nil,
        results: [
          {
            id: 4101,
            txt: "Twin Sisters Dunite Chromite Locality, Whatcom Co., WA",
            latitude: 48.7042,
            longitude: -121.9810,
            elements: "-Mg-Si-Fe-Cr-O-",
            minerals: [
              { "name" => "Forsterite" },
              { "name" => "Chromite" },
              { "name" => "Enstatite" }
            ],
            loc_type: "Alpine Ultramafic",
            country: "USA"
          }
        ]
      }.to_json

      page2_body = {
        count: 2,
        next: nil,
        previous: "https://api.mindat.org/localities/?page=1",
        results: [
          {
            id: 4102,
            name: "Hamilton Skagit Talc Mine",
            latitude: 48.5236,
            longitude: -121.9892,
            elements: [ "Mg", "Si" ],
            commodities: [ "Talc", "Soapstone" ],
            minerals: [ "Talc", "Chlorite", "Magnesite" ],
            loc_type: [ "Mine", "Metamorphic Deposit" ]
          }
        ]
      }.to_json

      page1_stub = stub_request(:get, MINDAT_URL)
        .with(
          headers: { "Authorization" => "Token #{TEST_TOKEN}" },
          query: hash_including("lat_min", "lat_max", "lon_min", "lon_max")
        )
        .to_return(status: 200, body: page1_body, headers: { "Content-Type" => "application/json" })

      page2_stub = stub_request(:get, "https://api.mindat.org/localities/?page=2&lat_min=46.80376")
        .with(headers: { "Authorization" => "Token #{TEST_TOKEN}" })
        .to_return(status: 200, body: page2_body, headers: { "Content-Type" => "application/json" })

      results = Clients::MindatClient.search_nearby(
        lat: 48.60,
        lng: -121.98,
        radius_km: 50,
        api_token: TEST_TOKEN
      )

      assert_requested page1_stub, times: 1
      assert_requested page2_stub, times: 1
      assert_equal 2, results.size
      assert results.all?(&:persisted?)
      assert_equal [ "mindat" ], results.map(&:source).uniq

      first = MineralOccurrence.find_by!(source: "mindat", external_id: "4101")
      assert_equal "Twin Sisters Dunite Chromite Locality, Whatcom Co., WA", first.name
      assert_equal "Alpine Ultramafic", first.deposit_type
      assert_includes first.minerals, "Chromite"
      assert_includes first.minerals, "Forsterite"
      assert_includes first.commodities, "Chromium"
      assert_includes first.commodities, "Silica"
      assert_equal "https://www.mindat.org/loc-4101.html", first.raw_metadata["mindat_url"]
      assert_in_delta 48.7042, first.latitude, 0.0001
      assert_in_delta(-121.9810, first.longitude, 0.0001)

      second = MineralOccurrence.find_by!(source: "mindat", external_id: "4102")
      assert_equal "Hamilton Skagit Talc Mine", second.name
      assert_equal "Mine, Metamorphic Deposit", second.deposit_type
      assert_includes second.commodities, "Talc"
      assert_includes second.minerals, "Magnesite"
    end

    test "returns cached mindat occurrences within radius and bypasses cache with force_refresh" do
      cached = MineralOccurrence.create!(
        source: "mindat",
        external_id: "5501",
        name: "Cached Enumclaw Locality",
        commodities: [ "Basalt" ],
        minerals: [ "Plagioclase" ],
        deposit_type: "Quarry",
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG
      )

      stub = stub_request(:get, MINDAT_URL)
        .with(query: hash_including("lat_min"))
        .to_return(
          status: 200,
          body: {
            results: [
              {
                id: 5501,
                txt: "Refreshed Enumclaw Basalt Locality",
                latitude: TACOMA_LAT,
                longitude: TACOMA_LNG,
                minerals: [ "Augite", "Plagioclase" ],
                loc_type: "Volcanic Quarry"
              }
            ]
          }.to_json
        )

      cached_results = Clients::MindatClient.search_nearby(
        lat: TACOMA_LAT,
        lng: TACOMA_LNG,
        radius_km: 50,
        api_token: TEST_TOKEN
      )
      assert_equal [ cached.id ], cached_results.map(&:id)
      assert_not_requested stub

      refreshed = Clients::MindatClient.search_nearby(
        lat: TACOMA_LAT,
        lng: TACOMA_LNG,
        radius_km: 50,
        api_token: TEST_TOKEN,
        force_refresh: true
      )
      assert_requested stub, times: 1
      assert_equal [ cached.id ], refreshed.map(&:id)
      assert_equal "Refreshed Enumclaw Basalt Locality", cached.reload.name
      assert_equal 1, MineralOccurrence.by_source("mindat").count
    end

    test "retries on 429 and 503 and degrades gracefully to empty array on timeout" do
      success_body = {
        results: [
          {
            id: 6601,
            txt: "Spokane Kaolin Pit",
            latitude: 47.55,
            longitude: -117.10,
            minerals: [ "Kaolinite", "Quartz" ]
          }
        ]
      }.to_json

      retry_stub = stub_request(:get, MINDAT_URL)
        .with(query: hash_including("lat_min"))
        .to_return(
          { status: 429, body: "Rate limit" },
          { status: 503, body: "Unavailable" },
          { status: 200, body: success_body }
        )

      recovered = Clients::MindatClient.new(api_token: TEST_TOKEN, retry_delay: 0.0)
        .search_nearby(lat: 47.55, lng: -117.10, radius_km: 25)

      assert_requested retry_stub, times: 3
      assert_equal 1, recovered.size
      assert_equal "6601", recovered.first.external_id

      WebMock.reset!
      timeout_stub = stub_request(:get, MINDAT_URL)
        .with(query: hash_including("lat_min"))
        .to_timeout

      assert_equal [], Clients::MindatClient.new(api_token: TEST_TOKEN, retry_delay: 0.0)
        .search_nearby(lat: 44.0, lng: -120.0, radius_km: 25)
      assert_requested timeout_stub, times: 3

      assert_raises(Clients::MindatClient::NetworkError) do
        Clients::MindatClient.new(api_token: TEST_TOKEN, retry_delay: 0.0)
          .search_nearby!(lat: 44.0, lng: -120.0, radius_km: 25)
      end
    end

    test "rejects invalid coordinates without making HTTP calls" do
      stub = stub_request(:get, /api\.mindat\.org/)

      assert_equal [], Clients::MindatClient.search_nearby(lat: 95.0, lng: -122.4, api_token: TEST_TOKEN)
      assert_equal [], Clients::MindatClient.search_nearby(lat: "bad", lng: -122.4, api_token: TEST_TOKEN)
      assert_not_requested stub
    end
  end
end
