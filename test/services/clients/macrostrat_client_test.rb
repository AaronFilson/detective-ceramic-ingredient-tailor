# frozen_string_literal: true

require "test_helper"

module Clients
  class MacrostratClientTest < ActiveSupport::TestCase
    TACOMA_LAT = 47.2529
    TACOMA_LNG = -122.4443
    MACROSTRAT_URL_PATTERN = %r{\Ahttps://macrostrat\.org/api/v2/geologic_units/map}

    setup do
      WebMock.reset!
    end

    test "fetches GeoJSON Polygon FeatureCollection, persists SRID 4326 boundary, and populates lithology" do
      geojson_body = {
        type: "FeatureCollection",
        features: [
          {
            type: "Feature",
            properties: {
              map_id: 41001,
              name: "Vashon Drift",
              strat_name: "Fraser Glaciation",
              age: "Pleistocene",
              lith: "Major:{till, glacial drift}, Minor:{clay, silt}",
              liths: [
                { lith_id: 10, name: "Glacial Till", type: "Unconsolidated" },
                { lith_id: 14, name: "Clay", type: "Siliciclastic" }
              ],
              descrip: "Glaciolacustrine clay and glacial till",
              color: "#f2e8b5"
            },
            geometry: {
              type: "Polygon",
              coordinates: [[
                [-122.55, 47.20],
                [-122.35, 47.20],
                [-122.35, 47.32],
                [-122.55, 47.32],
                [-122.55, 47.20]
              ]]
            }
          }
        ]
      }.to_json

      stub = stub_request(:get, MACROSTRAT_URL_PATTERN)
        .with(query: { lat: TACOMA_LAT.to_s, lng: TACOMA_LNG.to_s, format: "geojson" })
        .to_return(status: 200, body: geojson_body, headers: { "Content-Type" => "application/json" })

      unit = Clients::MacrostratClient.lookup(lat: TACOMA_LAT, lng: TACOMA_LNG)

      assert_requested stub, times: 1
      assert_kind_of GeologicUnit, unit
      assert unit.persisted?
      assert_equal 41001, unit.macrostrat_id
      assert_equal "Vashon Drift", unit.name
      assert_equal "Fraser Glaciation", unit.strat_name
      assert_equal "Pleistocene", unit.age
      assert_equal "#f2e8b5", unit.lithology["color"]
      assert_equal "Major:{till, glacial drift}, Minor:{clay, silt}", unit.lithology["raw"]
      assert_includes unit.lithology_terms, "till"
      assert_includes unit.lithology_terms, "clay"
      assert_includes unit.lithology_terms, "glacial till"

      unit.reload
      assert_not_nil unit.boundary
      assert_equal 4326, unit.boundary.srid
      assert_equal "Polygon", unit.boundary.geometry_type.type_name
    end

    test "fetches and persists GeoJSON MultiPolygon FeatureCollection with SRID 4326" do
      lat = 46.85
      lng = -121.75

      geojson_body = {
        type: "FeatureCollection",
        features: [
          {
            type: "Feature",
            properties: {
              map_id: 41002,
              name: "Cascade Volcanic Complex",
              strat_name: "Ohanapecosh Formation",
              b_int_name: "Eocene",
              t_int_name: "Oligocene",
              lith: "Major:{Andesite, Basalt}, Minor:{Tuff}",
              color: "#d97757"
            },
            geometry: {
              type: "MultiPolygon",
              coordinates: [
                [[[-121.90, 46.75], [-121.65, 46.75], [-121.65, 46.95], [-121.90, 46.95], [-121.90, 46.75]]],
                [[[-121.50, 47.00], [-121.30, 47.00], [-121.30, 47.15], [-121.50, 47.15], [-121.50, 47.00]]]
              ]
            }
          }
        ]
      }.to_json

      stub_request(:get, MACROSTRAT_URL_PATTERN)
        .with(query: hash_including("format" => "geojson"))
        .to_return(status: 200, body: geojson_body, headers: { "Content-Type" => "application/json" })

      unit = Clients::MacrostratClient.lookup(lat: lat, lng: lng)

      assert unit.persisted?
      assert_equal 41002, unit.macrostrat_id
      assert_equal "Eocene - Oligocene", unit.age
      assert_equal %w[andesite basalt tuff], unit.lithology_terms

      unit.reload
      assert_equal 4326, unit.boundary.srid
      assert_equal "MultiPolygon", unit.boundary.geometry_type.type_name

      # Subsequent lookup inside second polygon hits PostGIS ST_Covers cache without HTTP
      WebMock.reset!
      http_stub = stub_request(:get, MACROSTRAT_URL_PATTERN)
      cached = Clients::MacrostratClient.lookup(lat: 47.08, lng: -121.40)
      assert_equal unit.id, cached.id
      assert_not_requested http_stub
    end

    test "returns cached PostGIS GeologicUnit without making HTTP request when ST_Covers matches" do
      factory = RGeo::Cartesian.preferred_factory(srid: 4326)
      polygon = RGeo::GeoJSON.decode(
        {
          "type" => "Polygon",
          "coordinates" => [[
            [-122.55, 47.20],
            [-122.35, 47.20],
            [-122.35, 47.32],
            [-122.55, 47.32],
            [-122.55, 47.20]
          ]]
        },
        geo_factory: factory
      )

      cached = GeologicUnit.create!(
        macrostrat_id: 41010,
        name: "Cached Lawton Clay",
        strat_name: "Lawton Clay Member",
        age: "Pleistocene",
        lithology: { "raw" => "clay, silt" },
        boundary: polygon
      )

      stub = stub_request(:get, MACROSTRAT_URL_PATTERN)

      result = Clients::MacrostratClient.lookup(lat: TACOMA_LAT, lng: TACOMA_LNG)

      assert_equal cached.id, result.id
      assert_not_requested stub
    end

    test "force_refresh bypasses PostGIS cache and updates existing unit idempotently" do
      factory = RGeo::Cartesian.preferred_factory(srid: 4326)
      polygon = RGeo::GeoJSON.decode(
        {
          "type" => "Polygon",
          "coordinates" => [[
            [-122.55, 47.20],
            [-122.35, 47.20],
            [-122.35, 47.32],
            [-122.55, 47.32],
            [-122.55, 47.20]
          ]]
        },
        geo_factory: factory
      )

      existing = GeologicUnit.create!(
        macrostrat_id: 41011,
        name: "Old Name",
        age: "Unknown",
        lithology: { "raw" => "clay" },
        boundary: polygon
      )

      refreshed_body = {
        type: "FeatureCollection",
        features: [
          {
            type: "Feature",
            properties: {
              map_id: 41011,
              name: "Updated Vashon Drift",
              strat_name: "Fraser Glaciation",
              age: "Late Pleistocene",
              lith: "Major:{glacial till, clay}"
            },
            geometry: {
              type: "Polygon",
              coordinates: [[
                [-122.55, 47.20],
                [-122.35, 47.20],
                [-122.35, 47.32],
                [-122.55, 47.32],
                [-122.55, 47.20]
              ]]
            }
          }
        ]
      }.to_json

      stub = stub_request(:get, MACROSTRAT_URL_PATTERN)
        .to_return(status: 200, body: refreshed_body)

      result = Clients::MacrostratClient.lookup(lat: TACOMA_LAT, lng: TACOMA_LNG, force_refresh: true)

      assert_requested stub, times: 1
      assert_equal existing.id, result.id
      assert_equal "Updated Vashon Drift", result.reload.name
      assert_equal "Late Pleistocene", result.age
      assert_equal 1, GeologicUnit.where(macrostrat_id: 41011).count
    end

    test "handles Macrostrat JSON success.data array fallback format gracefully" do
      json_body = {
        success: {
          v: 2,
          data: [
            {
              map_id: 41020,
              name: "Columbia River Basalt Group",
              strat_name: "Wanapum Basalt",
              age: "Miocene",
              lith: "Major:{basalt}",
              descrip: "Flood basalt flows",
              color: "#8b4513"
            }
          ]
        }
      }.to_json

      stub_request(:get, MACROSTRAT_URL_PATTERN)
        .to_return(status: 200, body: json_body, headers: { "Content-Type" => "application/json" })

      unit = Clients::MacrostratClient.lookup(lat: 46.9445, lng: -119.9870)

      assert unit.persisted?
      assert_equal 41020, unit.macrostrat_id
      assert_equal "Columbia River Basalt Group", unit.name
      assert_equal "Wanapum Basalt", unit.strat_name
      assert_includes unit.lithology_terms, "basalt"
      assert_nil unit.boundary
    end

    test "returns nil when Macrostrat returns an empty FeatureCollection" do
      empty_body = { type: "FeatureCollection", features: [] }.to_json

      stub_request(:get, MACROSTRAT_URL_PATTERN)
        .to_return(status: 200, body: empty_body)

      assert_nil Clients::MacrostratClient.lookup(lat: 0.0, lng: 0.0)
      assert_nil Clients::MacrostratClient.lookup!(lat: 0.0, lng: 0.0)
    end

    test "retries on HTTP 503 and succeeds on subsequent attempt" do
      success_body = {
        type: "FeatureCollection",
        features: [
          {
            type: "Feature",
            properties: { map_id: 41030, name: "Recovered Unit", lith: "shale" },
            geometry: nil
          }
        ]
      }.to_json

      stub = stub_request(:get, MACROSTRAT_URL_PATTERN)
        .to_return(
          { status: 503, body: "Service Unavailable" },
          { status: 429, body: "Too Many Requests" },
          { status: 200, body: success_body }
        )

      unit = Clients::MacrostratClient.new(retry_delay: 0.0).lookup(lat: 47.48, lng: -122.21)

      assert_requested stub, times: 3
      assert_equal 41030, unit.macrostrat_id
      assert_equal "Recovered Unit", unit.name
    end

    test "retries on network timeout and succeeds when later attempt responds" do
      success_body = {
        success: {
          v: 2,
          data: [{ map_id: 41031, name: "Timeout Recovery Unit", lith: "granite" }]
        }
      }.to_json

      stub = stub_request(:get, MACROSTRAT_URL_PATTERN)
        .to_timeout
        .then
        .to_return(status: 200, body: success_body)

      unit = Clients::MacrostratClient.new(retry_delay: 0.0).lookup(lat: 48.49, lng: -121.18)

      assert_requested stub, times: 2
      assert_equal 41031, unit.macrostrat_id
    end

    test "lookup returns nil gracefully on persistent network failure while lookup! raises Error" do
      stub = stub_request(:get, MACROSTRAT_URL_PATTERN).to_timeout

      assert_nil Clients::MacrostratClient.new(retry_delay: 0.0).lookup(lat: 47.0, lng: -122.0)
      assert_requested stub, times: 3

      assert_raises(Clients::MacrostratClient::Error) do
        Clients::MacrostratClient.new(retry_delay: 0.0).lookup!(lat: 47.0, lng: -122.0)
      end
    end

    test "lookup returns nil gracefully on HTTP 500 failure and invalid coordinates" do
      stub_request(:get, MACROSTRAT_URL_PATTERN).to_return(status: 500, body: "Internal Server Error")

      assert_nil Clients::MacrostratClient.new(retry_delay: 0.0).lookup(lat: 47.0, lng: -122.0)
      assert_nil Clients::MacrostratClient.lookup(lat: nil, lng: -122.0)
      assert_nil Clients::MacrostratClient.lookup(lat: 99.0, lng: -122.0)

      assert_raises(Clients::MacrostratClient::Error) do
        Clients::MacrostratClient.lookup!(lat: 99.0, lng: -122.0)
      end
    end

    test "accepts numeric string coordinates as passed from controller params" do
      body = {
        success: {
          v: 2,
          data: [{ map_id: 41040, name: "String Coord Unit", lith: "alluvial clay" }]
        }
      }.to_json

      stub_request(:get, MACROSTRAT_URL_PATTERN)
        .to_return(status: 200, body: body)

      unit = Clients::MacrostratClient.lookup(lat: "47.2529", lng: "-122.4443")

      assert_equal 41040, unit.macrostrat_id
      assert_equal "String Coord Unit", unit.name
    end

    test "does not retry non-retryable 404 responses and handles malformed JSON gracefully" do
      stub_404 = stub_request(:get, MACROSTRAT_URL_PATTERN)
        .to_return(status: 404, body: "Not Found")

      assert_nil Clients::MacrostratClient.new(retry_delay: 0.0).lookup(lat: 45.0, lng: -120.0)
      assert_requested stub_404, times: 1

      WebMock.reset!
      stub_request(:get, MACROSTRAT_URL_PATTERN)
        .to_return(status: 200, body: "{invalid-json")

      assert_nil Clients::MacrostratClient.lookup(lat: 45.0, lng: -120.0)
      assert_raises(Clients::MacrostratClient::Error) do
        Clients::MacrostratClient.lookup!(lat: 45.0, lng: -120.0)
      end
    end
  end
end
