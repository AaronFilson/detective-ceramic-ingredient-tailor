# frozen_string_literal: true

require "test_helper"

class MineralOccurrencesControllerTest < ActionDispatch::IntegrationTest
  TACOMA_LAT = 47.2529
  TACOMA_LNG = -122.4443
  MRDS_URL = "https://mrdata.usgs.gov/services/mrds"
  MINDAT_URL = "https://api.mindat.org/localities/"

  setup do
    WebMock.reset!
    MineralOccurrence.delete_all
    @prev_mindat_token = ENV["MINDAT_API_TOKEN"]
    ENV["MINDAT_API_TOKEN"] = nil

    @near_deposit = MineralOccurrence.create!(
      source: "pnw_curated_atlas",
      external_id: "CTRL-1",
      name: "Enumclaw Cascade Andesite Quarry",
      deposit_type: "Volcanic Flow Quarry",
      commodities: [ "Andesite", "Iron" ],
      minerals: [ "Plagioclase", "Magnetite" ],
      latitude: 47.2043,
      longitude: -121.9915,
      raw_metadata: { "ceramic_role" => "Single-rock tenmoku glaze base", "region" => "West Cascades" }
    )
    @closer_deposit = MineralOccurrence.create!(
      source: "usgs_mrds",
      external_id: "CTRL-2",
      name: "Puyallup Silica Sand Pit",
      deposit_type: "Alluvial Silica",
      commodities: [ "Silica", "Quartz" ],
      minerals: [ "Quartz" ],
      latitude: 47.1950,
      longitude: -122.2930
    )
    @far_deposit = MineralOccurrence.create!(
      source: "pnw_curated_atlas",
      external_id: "CTRL-3",
      name: "Spokane Freeman Kaolin",
      deposit_type: "Residual Kaolin",
      commodities: [ "Kaolin", "Clay" ],
      minerals: [ "Kaolinite" ],
      latitude: 47.5150,
      longitude: -117.1770
    )
  end

  teardown do
    ENV["MINDAT_API_TOKEN"] = @prev_mindat_token
  end

  test "GET /mineral_occurrences.json returns nearby deposits sorted by PostGIS distance with full fields" do
    get mineral_occurrences_path(format: :json), params: {
      lat: TACOMA_LAT,
      lng: TACOMA_LNG,
      radius_km: 50
    }

    assert_response :success
    payload = JSON.parse(response.body)

    assert_kind_of Array, payload
    assert_equal 2, payload.size
    assert_equal [ "Puyallup Silica Sand Pit", "Enumclaw Cascade Andesite Quarry" ], payload.map { |r| r["name"] }
    assert_operator payload[0]["distance_km"], :<, payload[1]["distance_km"]

    first = payload.first
    assert_equal "usgs_mrds", first["source"]
    assert_equal "Alluvial Silica", first["deposit_type"]
    assert_equal [ "Silica", "Quartz" ], first["commodities"]
    assert_equal [ "Quartz" ], first["minerals"]
    assert_equal [ "silica", "quartz" ], first["ceramic_highlights"]
    assert_in_delta 47.1950, first["lat"], 0.001
    assert_in_delta(-122.2930, first["lng"], 0.001)
    assert_in_delta 13.1, first["distance_km"], 2.0
  end

  test "GET /mineral_occurrences.json supports source filtering and rejects invalid coordinates" do
    get mineral_occurrences_path(format: :json), params: {
      lat: TACOMA_LAT,
      lng: TACOMA_LNG,
      radius_km: 50,
      source: "pnw_curated_atlas"
    }

    assert_response :success
    payload = JSON.parse(response.body)
    assert_equal [ "Enumclaw Cascade Andesite Quarry" ], payload.map { |r| r["name"] }

    get mineral_occurrences_path(format: :json), params: { lat: "bad", lng: TACOMA_LNG }
    assert_response :bad_request
    assert_includes JSON.parse(response.body)["error"], "Valid lat and lng"
  end

  test "POST /mineral_occurrences/refresh triggers live MRDS lookup and replaces #mineral_occurrences_card via Turbo Stream" do
    mrds_gml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <wfs:FeatureCollection xmlns:ms="http://mapserver.gis.umn.edu/mapserver" xmlns:wfs="http://www.opengis.net/wfs" xmlns:gml="http://www.opengis.net/gml">
        <gml:featureMember>
          <ms:mrds fid="mrds.777001">
            <ms:dep_id>777001</ms:dep_id>
            <ms:site_name>Lake Cushman Pyrolusite Prospect</ms:site_name>
            <ms:commod1>Manganese</ms:commod1>
            <ms:ore>Pyrolusite, Braunite</ms:ore>
            <ms:dep_type>Volcanogenic Manganese</ms:dep_type>
            <ms:latitude>47.3000</ms:latitude>
            <ms:longitude>-122.6500</ms:longitude>
          </ms:mrds>
        </gml:featureMember>
      </wfs:FeatureCollection>
    XML

    mrds_stub = stub_request(:get, MRDS_URL)
      .with(query: hash_including("service" => "WFS", "typeName" => "mrds-high"))
      .to_return(status: 200, body: mrds_gml, headers: { "Content-Type" => "text/xml" })

    assert_difference -> { MineralOccurrence.count }, 1 do
      post refresh_mineral_occurrences_path,
        params: { lat: TACOMA_LAT, lng: TACOMA_LNG, radius_km: 50 },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_requested mrds_stub, times: 1
    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, '<turbo-stream action="replace" target="mineral_occurrences_card">'
    assert_includes response.body, "Lake Cushman Pyrolusite Prospect"
    assert_includes response.body, "Volcanogenic Manganese"
    assert_includes response.body, "Manganese"
    assert_includes response.body, "Pyrolusite"
    assert_includes response.body, "USGS MRDS"
    assert_includes response.body, "Live refresh complete: 1 USGS MRDS occurrence(s) synced"
    assert_includes response.body, "km"
  end

  test "POST /mineral_occurrences/refresh responds with JSON including Mindat when configured" do
    ENV["MINDAT_API_TOKEN"] = "ctrl-mindat-token"

    stub_request(:get, MRDS_URL)
      .with(query: hash_including("service" => "WFS"))
      .to_return(
        status: 200,
        body: { type: "FeatureCollection", features: [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    mindat_stub = stub_request(:get, MINDAT_URL)
      .with(
        headers: { "Authorization" => "Token ctrl-mindat-token" },
        query: hash_including("lat_min")
      )
      .to_return(
        status: 200,
        body: {
          results: [
            {
              id: 50501,
              txt: "Tacoma Mindat Basalt Outcrop",
              latitude: 47.2600,
              longitude: -122.4500,
              commodities: [ "Basalt" ],
              minerals: [ "Plagioclase" ],
              loc_type: "Outcrop"
            }
          ]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    post refresh_mineral_occurrences_path(format: :json), params: {
      lat: TACOMA_LAT,
      lng: TACOMA_LNG,
      radius_km: 50
    }

    assert_requested mindat_stub, times: 1
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "ok", body["status"]
    assert_equal 0, body.dig("refreshed_counts", "usgs_mrds")
    assert_equal 1, body.dig("refreshed_counts", "mindat")
    assert body["mineral_occurrences"].any? { |occ| occ["name"] == "Tacoma Mindat Basalt Outcrop" }
  end

  test "POST /mineral_occurrences/refresh returns 422 on invalid coordinates" do
    post refresh_mineral_occurrences_path,
      params: { lat: "invalid", lng: TACOMA_LNG },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :unprocessable_entity
    assert_includes response.body, "Valid lat and lng parameters are required"

    post refresh_mineral_occurrences_path(format: :json), params: { lat: "", lng: "" }
    assert_response :unprocessable_entity
    assert_includes JSON.parse(response.body)["error"], "Valid lat and lng"
  end
end
