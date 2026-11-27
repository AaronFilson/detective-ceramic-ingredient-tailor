# frozen_string_literal: true

require "test_helper"

module Clients
  class GeorocClientTest < ActiveSupport::TestCase
    BASE_URL = "https://api-test.georoc.eu"

    setup do
      WebMock.reset!
    end

    test "configured? reflects presence of API key" do
      assert_not Clients::GeorocClient.configured?(api_key: nil)
      assert_not Clients::GeorocClient.configured?(api_key: "   ")
      assert Clients::GeorocClient.configured?(api_key: "digis-secret-key")
    end

    test "ping returns true on 200 and false on server or network error" do
      ping_stub = stub_request(:get, "#{BASE_URL}/api/v1/ping")
        .to_return(status: 200, body: { status: "ok" }.to_json, headers: { "Content-Type" => "application/json" })

      assert Clients::GeorocClient.ping(base_url: BASE_URL, api_key: nil, retry_delay: 0.0)
      assert_requested ping_stub, times: 1

      stub_request(:get, "#{BASE_URL}/api/v1/ping")
        .to_return(status: 503, body: "Service Unavailable")

      assert_not Clients::GeorocClient.ping(base_url: BASE_URL, api_key: nil, max_retries: 0, retry_delay: 0.0)
    end

    test "query_samples gracefully returns empty array without HTTP calls when API key is absent" do
      result = Clients::GeorocClient.query_samples(
        rock_type: "BASALT",
        api_key: nil,
        base_url: BASE_URL
      )

      assert_equal [], result
      assert_not_requested :get, %r{georoc\.eu}
    end

    test "query_samples sends DIGIS-API-ACCESSKEY header and paginates with limit and offset" do
      page1_stub = stub_request(:get, "#{BASE_URL}/api/v1/queries/samples")
        .with(
          headers: { "DIGIS-API-ACCESSKEY" => "test-digis-key" },
          query: hash_including(
            "rocktype" => "ANDESITE",
            "latitude_min" => "45.5",
            "latitude_max" => "49.0",
            "longitude_min" => "-124.8",
            "longitude_max" => "-117.0",
            "limit" => "2",
            "offset" => "0"
          )
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            data: [
              { "sample_name" => "G-01", "rock_name" => "ANDESITE" },
              { "sample_name" => "G-02", "rock_name" => "ANDESITE" }
            ]
          }.to_json
        )

      page2_stub = stub_request(:get, "#{BASE_URL}/api/v1/queries/samples")
        .with(
          headers: { "DIGIS-API-ACCESSKEY" => "test-digis-key" },
          query: hash_including(
            "rocktype" => "ANDESITE",
            "limit" => "2",
            "offset" => "2"
          )
        )
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: {
            data: [
              { "sample_name" => "G-03", "rock_name" => "ANDESITE" }
            ]
          }.to_json
        )

      records = Clients::GeorocClient.query_samples(
        rock_type: "ANDESITE",
        bbox: { min_lat: 45.5, max_lat: 49.0, min_lng: -124.8, max_lng: -117.0 },
        limit: 2,
        offset: 0,
        max_pages: 5,
        base_url: BASE_URL,
        api_key: "test-digis-key",
        retry_delay: 0.0
      )

      assert_requested page1_stub, times: 1
      assert_requested page2_stub, times: 1
      assert_equal %w[G-01 G-02 G-03], records.map { |r| r["sample_name"] }
    end

    test "query_samples retries transient 503 errors and returns empty array on permanent failure" do
      stub_request(:get, "#{BASE_URL}/api/v1/queries/samples")
        .with(
          headers: { "DIGIS-API-ACCESSKEY" => "retry-key" },
          query: hash_including("limit" => "10", "offset" => "0")
        )
        .to_return(status: 503, body: "Temporarily Unavailable")
        .then
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { samples: [ { "sample_name" => "G-RETRY-1" } ] }.to_json
        )

      records = Clients::GeorocClient.query_samples(
        limit: 10,
        base_url: BASE_URL,
        api_key: "retry-key",
        retry_delay: 0.0
      )
      assert_equal [ { "sample_name" => "G-RETRY-1" } ], records

      stub_request(:get, "#{BASE_URL}/api/v1/queries/samples")
        .with(
          headers: { "DIGIS-API-ACCESSKEY" => "fail-key" },
          query: hash_including("limit" => "10", "offset" => "0")
        )
        .to_return(status: 401, body: "Unauthorized")

      failed = Clients::GeorocClient.query_samples(
        limit: 10,
        base_url: BASE_URL,
        api_key: "fail-key",
        retry_delay: 0.0
      )
      assert_equal [], failed
    end
  end
end
