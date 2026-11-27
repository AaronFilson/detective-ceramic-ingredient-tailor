# frozen_string_literal: true

require "test_helper"

module Clients
  class GlazecalcPushClientTest < ActiveSupport::TestCase
    setup do
      WebMock.reset!

      @sample = UserSample.create!(
        title: "Puget Sound Bluff Clay",
        material_category: :wild_clay,
        latitude: 47.2529,
        longitude: -122.4443,
        notes: "Collected from shoreline bluff"
      )

      @assay = @sample.assay_results.create!(
        source_type: :spatial_heuristic_estimate,
        confidence_score: 0.82,
        oxides: {
          "SiO2" => 61.5,
          "Al2O3" => 18.0,
          "Fe2O3" => 4.8,
          "CaO" => 2.6,
          "MgO" => 1.4,
          "Na2O" => 1.1,
          "K2O" => 1.8,
          "LOI" => 8.8
        },
        reasoning_log: [ "Matched Puget Sound glacial clay assays" ]
      )
    end

    test "pushes exact RECORD_FIELDS payload on HTTP 201 Created with bearer auth" do
      captured_body = nil

      stub = stub_request(:post, "https://glazecalc.com/api/materials")
        .with(
          headers: {
            "Authorization" => "Bearer gc_live_secret_token_123",
            "Content-Type" => "application/json",
            "Accept" => "application/json"
          }
        ) { |req| captured_body = JSON.parse(req.body); true }
        .to_return(
          status: 201,
          headers: { "Content-Type" => "application/json" },
          body: { id: "mat_42", name: "Puget Sound Bluff Clay" }.to_json
        )

      result = GlazecalcPushClient.call(@sample, api_token: "gc_live_secret_token_123")

      assert_requested stub, times: 1
      assert result.success?
      assert_equal 201, result.status
      assert_equal "mat_42", result.material_id
      assert_equal "Puget Sound Bluff Clay", result.material_name
      assert_includes result.message, "Puget Sound Bluff Clay"
      assert_includes result.message, "mat_42"
      assert_equal({ "id" => "mat_42", "name" => "Puget Sound Bluff Clay" }, result.response_body)

      # Ensure payload contains exact RECORD_FIELDS.materials keys and excludes internal metadata
      assert_equal GlazecalcPushClient::RECORD_FIELDS.sort, captured_body.keys.sort
      assert_equal "Puget Sound Bluff Clay", captured_body["name"]
      assert_equal "percent", captured_body["percentmole"]
      assert_equal 100.0, captured_body["molecularweight"]
      assert_in_delta 8.8, captured_body["loi"], 0.001
      assert_not captured_body.key?("umf")
      assert_not captured_body.key?("source")
      assert_not captured_body.key?("oxideAnalysis")
    end

    test "supports custom self-hosted base_url with trailing slash and HTTP 200 response" do
      stub = stub_request(:post, "http://localhost:4100/api/materials")
        .to_return(
          status: 200,
          headers: { "Content-Type" => "application/json" },
          body: { material: { id: "local_9", name: "Puget Sound Bluff Clay" } }.to_json
        )

      result = GlazecalcPushClient.call(
        @assay,
        api_token: "local-dev-token",
        base_url: "http://localhost:4100///"
      )

      assert_requested stub, times: 1
      assert result.success?
      assert_equal 200, result.status
      assert_equal "local_9", result.material_id
    end

    test "handles HTTP 401 and 403 auth/scope errors with Read and change reminder" do
      [ 401, 403 ].each do |code|
        WebMock.reset!
        stub_request(:post, "https://glazecalc.com/api/materials")
          .to_return(
            status: code,
            headers: { "Content-Type" => "application/json" },
            body: { error: "Insufficient token scope" }.to_json
          )

        result = GlazecalcPushClient.call(@sample, api_token: "readonly_token_xyz")

        assert_not result.success?
        assert_equal code, result.status
        assert_nil result.material_id
        assert_includes result.message, "Read and change"
        assert_includes result.message, "Insufficient token scope"
        assert_not_includes result.message, "readonly_token_xyz"
      end
    end

    test "handles HTTP 409 and 422 validation errors gracefully" do
      stub_request(:post, "https://glazecalc.com/api/materials")
        .to_return(
          status: 422,
          headers: { "Content-Type" => "application/json" },
          body: { error: "Material name already exists" }.to_json
        )

      result = GlazecalcPushClient.call(@sample, api_token: "valid_token")

      assert_not result.success?
      assert_equal 422, result.status
      assert_includes result.message, "HTTP 422"
      assert_includes result.message, "Material name already exists"

      WebMock.reset!
      stub_request(:post, "https://glazecalc.com/api/materials")
        .to_return(
          status: 409,
          headers: { "Content-Type" => "application/json" },
          body: { message: "Duplicate material" }.to_json
        )

      conflict = GlazecalcPushClient.call(@sample, api_token: "valid_token")
      assert_not conflict.success?
      assert_equal 409, conflict.status
      assert_includes conflict.message, "Duplicate material"
    end

    test "handles network timeout and connection failures gracefully without leaking token" do
      stub_request(:post, "https://glazecalc.com/api/materials").to_timeout

      timeout_result = GlazecalcPushClient.call(@sample, api_token: "super_secret_token_999")
      assert_not timeout_result.success?
      assert_nil timeout_result.status
      assert_match(/timed out/i, timeout_result.message)
      assert_not_includes timeout_result.message, "super_secret_token_999"

      WebMock.reset!
      stub_request(:post, "https://glazecalc.com/api/materials")
        .to_raise(Faraday::ConnectionFailed.new("Failed to open TCP connection with super_secret_token_999"))

      conn_result = GlazecalcPushClient.call(@sample, api_token: "super_secret_token_999")
      assert_not conn_result.success?
      assert_match(/Could not connect/i, conn_result.message)
      assert_not_includes conn_result.message, "super_secret_token_999"
    end

    test "rejects missing token without making HTTP request" do
      stub = stub_request(:post, %r{glazecalc\.com})

      result = GlazecalcPushClient.call(@sample, api_token: "   ")

      assert_not_requested stub
      assert_not result.success?
      assert_nil result.status
      assert_includes result.message, "API token is required"
    end

    test "rejects non-http/https base_url schemes cleanly without making HTTP request" do
      stub = stub_request(:any, /.*/)

      [ "ftp://glazecalc.com", "javascript:alert(1)", "file:///etc/passwd", "not a url", "" ].each do |bad_url|
        result = GlazecalcPushClient.call(@sample, api_token: "valid_token", base_url: bad_url)

        assert_not result.success?, "Expected #{bad_url.inspect} to be rejected"
        assert_nil result.status
        assert_match(/Invalid Glazecalc URL/i, result.message)
      end

      assert_not_requested stub
    end

    test "returns failure cleanly when sample has no assay result" do
      stub = stub_request(:any, /.*/)
      bare_sample = UserSample.create!(title: "Unanalyzed Clay", material_category: :wild_clay)

      result = GlazecalcPushClient.call(bare_sample, api_token: "valid_token")

      assert_not_requested stub
      assert_not result.success?
      assert_includes result.message, "has no AssayResult"
    end
  end
end
