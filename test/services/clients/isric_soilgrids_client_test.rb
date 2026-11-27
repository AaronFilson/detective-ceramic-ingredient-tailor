# frozen_string_literal: true

require "test_helper"

module Clients
  class IsricSoilgridsClientTest < ActiveSupport::TestCase
    CORNWALL_LAT = 50.3400
    CORNWALL_LNG = -4.7900
    SOILGRIDS_URL = "https://rest.isric.org/soilgrids/v2.0/properties/query"

    setup do
      WebMock.reset!
      SoilProfile.delete_all
    end

    def build_soilgrids_payload(
      clay: [ 210, 240, 290, 365, 340, 310 ],
      silt: [ 450, 440, 420, 415, 420, 430 ],
      sand: [ 340, 320, 290, 220, 240, 260 ],
      cec: [ 180, 195, 220, 245, 230, 210 ],
      phh2o: [ 58, 60, 62, 64, 65, 66 ],
      soc: [ 320, 240, 185, 110, 75, 45 ],
      value_key: "mean"
    )
      depths = [
        [ "0-5cm", 0, 5 ],
        [ "5-15cm", 5, 15 ],
        [ "15-30cm", 15, 30 ],
        [ "30-60cm", 30, 60 ],
        [ "60-100cm", 60, 100 ],
        [ "100-200cm", 100, 200 ]
      ]

      layer_data = {
        "clay" => clay,
        "silt" => silt,
        "sand" => sand,
        "cec" => cec,
        "phh2o" => phh2o,
        "soc" => soc
      }

      {
        type: "Feature",
        geometry: { type: "Point", coordinates: [ CORNWALL_LNG, CORNWALL_LAT ] },
        properties: {
          layers: layer_data.map do |name, vals|
            {
              name: name,
              unit_measure: { d_factor: 10 },
              depths: depths.each_with_index.map do |(label, top, bottom), idx|
                {
                  label: label,
                  range: { top_depth: top, bottom_depth: bottom, unit_depth: "cm" },
                  values: { value_key => vals[idx] }
                }
              end
            }
          end
        }
      }
    end

    test "queries ISRIC SoilGrids v2, applies exact unit conversions across 6 depths, and persists SoilProfile" do
      stub = stub_request(:get, /#{Regexp.escape(SOILGRIDS_URL)}/)
        .with(query: hash_including("lon" => "-4.790000", "lat" => "50.340000", "value" => "mean"))
        .to_return(
          status: 200,
          body: build_soilgrids_payload.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      profile = Clients::IsricSoilgridsClient.lookup(lat: CORNWALL_LAT, lng: CORNWALL_LNG)

      assert_requested stub, times: 1
      assert_kind_of SoilProfile, profile
      assert profile.persisted?
      assert_equal "isric_soilgrids", profile.source
      assert_equal "soilgrids:50.340:-4.790", profile.mukey
      assert_equal "ISRIC SoilGrids v2 (250m Global)", profile.map_unit_name
      # Peak clay horizon (30-60cm): 36.5% clay, 41.5% silt, 22.0% sand -> Clay Loam
      assert_equal "Clay Loam", profile.component_name
      assert_in_delta 36.5, profile.max_clay_pct.to_f, 0.01
      # Exact unit conversions: phh2o 64 -> 6.4, cec 245 -> 24.5 cmol/kg, soc 110 -> 11.0 g/kg
      assert_in_delta 6.4, profile.soil_ph.to_f, 0.01
      assert_in_delta 24.5, profile.cec.to_f, 0.01
      assert_in_delta 11.0, profile.organic_carbon.to_f, 0.01
      assert_not_nil profile.fetched_at
      assert_in_delta CORNWALL_LAT, profile.latitude, 0.0001
      assert_in_delta CORNWALL_LNG, profile.longitude, 0.0001

      assert_equal 6, profile.horizons.size
      assert_equal [ 0, 5, 15, 30, 60, 100 ], profile.horizons.map { |h| h["top_cm"] }
      assert_equal [ 5, 15, 30, 60, 100, 200 ], profile.horizons.map { |h| h["bottom_cm"] }

      top_hz = profile.horizons.first
      assert_in_delta 21.0, top_hz["clay_pct"], 0.01
      assert_in_delta 45.0, top_hz["silt_pct"], 0.01
      assert_in_delta 34.0, top_hz["sand_pct"], 0.01
      assert_in_delta 5.8, top_hz["ph"], 0.01
      assert_in_delta 18.0, top_hz["cec_cmol_kg"], 0.01
      assert_in_delta 32.0, top_hz["soc_g_kg"], 0.01

      best = profile.clay_rich_horizon
      assert_equal 30, best["top_cm"]
      assert_equal 60, best["bottom_cm"]
      assert_in_delta 36.5, best["clay_pct"], 0.01
    end

    test "encodes all 6 properties and 6 standard depths on the outbound Faraday request" do
      captured_query = nil
      test_connection = Faraday.new(url: Clients::IsricSoilgridsClient::BASE_URL) do |f|
        f.options.params_encoder = Faraday::FlatParamsEncoder
        f.adapter :test do |stubs|
          stubs.get(Clients::IsricSoilgridsClient::ENDPOINT_PATH) do |env|
            captured_query = env.url.query
            [ 200, { "Content-Type" => "application/json" }, build_soilgrids_payload.to_json ]
          end
        end
      end

      profile = Clients::IsricSoilgridsClient.new(connection: test_connection)
        .lookup(lat: CORNWALL_LAT, lng: CORNWALL_LNG)

      assert_not_nil profile
      assert_includes captured_query, "lon=-4.790000"
      assert_includes captured_query, "lat=50.340000"
      assert_includes captured_query, "value=mean"
      %w[clay silt sand cec phh2o soc].each do |prop|
        assert_includes captured_query, "property=#{prop}"
      end
      %w[0-5cm 5-15cm 15-30cm 30-60cm 60-100cm 100-200cm].each do |depth|
        assert_includes captured_query, "depth=#{depth}"
      end
    end

    test "gracefully reads Q0.5 median when mean is absent" do
      payload = build_soilgrids_payload(
        clay: [ 420, 440, 460, 480, 450, 430 ],
        silt: [ 410, 420, 420, 410, 420, 420 ],
        sand: [ 170, 140, 120, 110, 130, 150 ],
        cec: [ 95, 100, 105, 110, 105, 100 ],
        phh2o: [ 52, 51, 50, 49, 50, 51 ],
        soc: [ 150, 120, 90, 60, 40, 30 ],
        value_key: "Q0.5"
      )

      stub_request(:get, /#{Regexp.escape(SOILGRIDS_URL)}/)
        .to_return(status: 200, body: payload.to_json, headers: { "Content-Type" => "application/json" })

      profile = Clients::IsricSoilgridsClient.lookup(lat: 36.465, lng: 140.096)

      assert_not_nil profile
      assert_equal "Silty Clay", profile.component_name
      assert_in_delta 48.0, profile.max_clay_pct.to_f, 0.01
      assert_in_delta 4.9, profile.soil_ph.to_f, 0.01
      assert_in_delta 11.0, profile.cec.to_f, 0.01
      assert_in_delta 6.0, profile.organic_carbon.to_f, 0.01
    end

    test "classifies USDA soil texture triangle classes accurately" do
      assert_equal "Clay", Clients::IsricSoilgridsClient.classify_texture(52, 24, 24)
      assert_equal "Silty Clay", Clients::IsricSoilgridsClient.classify_texture(45, 45, 10)
      assert_equal "Sandy Clay", Clients::IsricSoilgridsClient.classify_texture(42, 10, 48)
      assert_equal "Clay Loam", Clients::IsricSoilgridsClient.classify_texture(34, 36, 30)
      assert_equal "Silty Clay Loam", Clients::IsricSoilgridsClient.classify_texture(34, 52, 14)
      assert_equal "Sandy Clay Loam", Clients::IsricSoilgridsClient.classify_texture(26, 20, 54)
      assert_equal "Silt Loam", Clients::IsricSoilgridsClient.classify_texture(16, 64, 20)
      assert_equal "Silt", Clients::IsricSoilgridsClient.classify_texture(6, 86, 8)
      assert_equal "Loam", Clients::IsricSoilgridsClient.classify_texture(18, 40, 42)
      assert_equal "Sandy Loam", Clients::IsricSoilgridsClient.classify_texture(12, 22, 66)
      assert_equal "Loamy Sand", Clients::IsricSoilgridsClient.classify_texture(6, 12, 82)
      assert_equal "Sand", Clients::IsricSoilgridsClient.classify_texture(3, 5, 92)
      assert_equal "Soil Profile", Clients::IsricSoilgridsClient.classify_texture(nil, 40, 40)
    end

    test "returns cached isric_soilgrids SoilProfile within 500m without HTTP request and ignores usda_ssurgo cache" do
      # An unrelated USDA SSURGO profile at the exact same spot should NOT satisfy the SoilGrids cache
      SoilProfile.create!(
        source: "usda_ssurgo",
        mukey: "999111",
        component_name: "Alderwood",
        latitude: CORNWALL_LAT,
        longitude: CORNWALL_LNG,
        fetched_at: 1.hour.ago
      )

      cached = SoilProfile.create!(
        source: "isric_soilgrids",
        mukey: "soilgrids:50.340:-4.790",
        map_unit_name: "ISRIC SoilGrids v2 (250m Global)",
        component_name: "Clay Loam",
        max_clay_pct: 36.5,
        soil_ph: 6.4,
        cec: 24.5,
        organic_carbon: 11.0,
        latitude: CORNWALL_LAT,
        longitude: CORNWALL_LNG,
        fetched_at: 1.hour.ago
      )

      stub = stub_request(:get, /#{Regexp.escape(SOILGRIDS_URL)}/)

      # ~333m north (within 500m radius)
      result = Clients::IsricSoilgridsClient.lookup(lat: CORNWALL_LAT + 0.003, lng: CORNWALL_LNG)

      assert_equal cached.id, result.id
      assert_not_requested stub
    end

    test "force_refresh bypasses 500m cache and upserts existing mukey idempotently" do
      existing = SoilProfile.create!(
        source: "isric_soilgrids",
        mukey: "soilgrids:50.340:-4.790",
        map_unit_name: "Old Label",
        component_name: "Old Texture",
        max_clay_pct: 15.0,
        latitude: CORNWALL_LAT,
        longitude: CORNWALL_LNG,
        fetched_at: 2.days.ago
      )

      stub = stub_request(:get, /#{Regexp.escape(SOILGRIDS_URL)}/)
        .to_return(
          status: 200,
          body: build_soilgrids_payload.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      refreshed = Clients::IsricSoilgridsClient.lookup(lat: CORNWALL_LAT, lng: CORNWALL_LNG, force_refresh: true)

      assert_requested stub, times: 1
      assert_equal existing.id, refreshed.id
      assert_equal "Clay Loam", refreshed.reload.component_name
      assert_in_delta 36.5, refreshed.max_clay_pct.to_f, 0.01
      assert_equal 1, SoilProfile.where(mukey: "soilgrids:50.340:-4.790").count
    end

    test "retries on 503, 429, and network timeout before succeeding" do
      payload_json = build_soilgrids_payload.to_json

      stub = stub_request(:get, /#{Regexp.escape(SOILGRIDS_URL)}/)
        .to_return(
          { status: 503, body: "Service Unavailable" },
          { status: 429, body: "Too Many Requests" },
          { status: 200, body: payload_json, headers: { "Content-Type" => "application/json" } }
        )

      profile = Clients::IsricSoilgridsClient.new(retry_delay: 0.0).lookup(lat: 49.2827, lng: -123.1207)

      assert_requested stub, times: 3
      assert_equal "isric_soilgrids", profile.source
      assert_equal "soilgrids:49.283:-123.121", profile.mukey

      WebMock.reset!
      timeout_stub = stub_request(:get, /#{Regexp.escape(SOILGRIDS_URL)}/)
        .to_timeout
        .then
        .to_return(status: 200, body: payload_json, headers: { "Content-Type" => "application/json" })

      recovered = Clients::IsricSoilgridsClient.new(retry_delay: 0.0).lookup(lat: -37.8136, lng: 144.9631)
      assert_requested timeout_stub, times: 2
      assert_equal "soilgrids:-37.814:144.963", recovered.mukey
    end

    test "lookup returns nil gracefully offline or on masked ocean pixel while lookup! raises on failure" do
      stub = stub_request(:get, /#{Regexp.escape(SOILGRIDS_URL)}/).to_timeout

      assert_nil Clients::IsricSoilgridsClient.new(retry_delay: 0.0).lookup(lat: 50.0, lng: -5.0)
      assert_requested stub, times: 3

      assert_raises(Clients::IsricSoilgridsClient::NetworkError) do
        Clients::IsricSoilgridsClient.new(retry_delay: 0.0).lookup!(lat: 50.0, lng: -5.0)
      end

      WebMock.reset!
      masked_ocean_payload = build_soilgrids_payload(
        clay: [ nil ] * 6,
        silt: [ nil ] * 6,
        sand: [ nil ] * 6,
        cec: [ nil ] * 6,
        phh2o: [ nil ] * 6,
        soc: [ nil ] * 6
      )
      stub_request(:get, /#{Regexp.escape(SOILGRIDS_URL)}/)
        .to_return(status: 200, body: masked_ocean_payload.to_json, headers: { "Content-Type" => "application/json" })

      assert_nil Clients::IsricSoilgridsClient.lookup(lat: 0.0, lng: -150.0)
      assert_nil Clients::IsricSoilgridsClient.lookup!(lat: 0.0, lng: -150.0)
      assert_equal 0, SoilProfile.where(source: "isric_soilgrids").count
    end

    test "rejects invalid coordinates before making any HTTP call" do
      stub = stub_request(:get, /#{Regexp.escape(SOILGRIDS_URL)}/)

      assert_nil Clients::IsricSoilgridsClient.lookup(lat: nil, lng: -4.79)
      assert_nil Clients::IsricSoilgridsClient.lookup(lat: 95.0, lng: -4.79)
      assert_nil Clients::IsricSoilgridsClient.lookup(lat: 50.34, lng: 185.0)
      assert_nil Clients::IsricSoilgridsClient.lookup(lat: "not-a-number", lng: -4.79)

      assert_raises(Clients::IsricSoilgridsClient::Error) do
        Clients::IsricSoilgridsClient.lookup!(lat: 91.0, lng: -4.79)
      end

      assert_not_requested stub
    end
  end
end
