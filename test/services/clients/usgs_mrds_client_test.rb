# frozen_string_literal: true

require "test_helper"

module Clients
  class UsgsMrdsClientTest < ActiveSupport::TestCase
    TACOMA_LAT = 47.2529
    TACOMA_LNG = -122.4443
    MRDS_URL = "https://mrdata.usgs.gov/services/mrds"

    setup do
      WebMock.reset!
      MineralOccurrence.delete_all
    end

    test "parses real USGS MRDS WFS GML/XML response via REXML, filters ceramic commodities, and persists occurrences" do
      gml_body = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <wfs:FeatureCollection
          xmlns:ms="http://mapserver.gis.umn.edu/mapserver"
          xmlns:wfs="http://www.opengis.net/wfs"
          xmlns:gml="http://www.opengis.net/gml">
          <gml:featureMember>
            <ms:mrds fid="mrds.10045678">
              <ms:msGeometry>
                <gml:Point srsName="EPSG:4326">
                  <gml:coordinates>-121.9892,48.5236</gml:coordinates>
                </gml:Point>
              </ms:msGeometry>
              <ms:dep_id>10045678</ms:dep_id>
              <ms:site_name>Hamilton Skagit Talc-Soapstone</ms:site_name>
              <ms:commod1>Talc-Soapstone</ms:commod1>
              <ms:commod2>Magnesite</ms:commod2>
              <ms:ore>Talc, Steatite</ms:ore>
              <ms:gangue>Chlorite, Dolomite</ms:gangue>
              <ms:dep_type>Metamorphic Ultramafic</ms:dep_type>
              <ms:dev_stat>Past Producer</ms:dev_stat>
              <ms:state>Washington</ms:state>
              <ms:county>Skagit</ms:county>
            </ms:mrds>
          </gml:featureMember>
          <gml:featureMember>
            <ms:mrds fid="mrds.10045679">
              <ms:dep_id>10045679</ms:dep_id>
              <ms:site_name>Silver Creek Precious Metal Prospect</ms:site_name>
              <ms:commod1>Silver</ms:commod1>
              <ms:commod2>Gold</ms:commod2>
              <ms:ore>Argentite</ms:ore>
              <ms:dep_type>Epithermal Vein</ms:dep_type>
              <ms:latitude>48.5100</ms:latitude>
              <ms:longitude>-121.9500</ms:longitude>
            </ms:mrds>
          </gml:featureMember>
          <gml:featureMember>
            <ms:mrds fid="mrds.10045680">
              <ms:dep_id>10045680</ms:dep_id>
              <ms:site_name>Twin Sisters Chromite &amp; Olivine</ms:site_name>
              <ms:commod1>Chromium</ms:commod1>
              <ms:commod2>Olivine</ms:commod2>
              <ms:ore>Chromite, Forsterite</ms:ore>
              <ms:model_name>Podiform Chromite</ms:model_name>
              <ms:latitude>48.7042</ms:latitude>
              <ms:longitude>-121.9810</ms:longitude>
            </ms:mrds>
          </gml:featureMember>
        </wfs:FeatureCollection>
      XML

      stub = stub_request(:get, MRDS_URL)
        .with(
          query: hash_including(
            "service" => "WFS",
            "version" => "1.0.0",
            "request" => "GetFeature",
            "typeName" => "mrds",
            "maxFeatures" => "50"
          )
        )
        .to_return(status: 200, body: gml_body, headers: { "Content-Type" => "text/xml; charset=utf-8" })

      results = Clients::UsgsMrdsClient.search_nearby(lat: 48.60, lng: -121.98, radius_km: 50)

      assert_requested stub, times: 1
      assert_equal 2, results.size
      assert_equal %w[10045678 10045680], results.map(&:external_id).sort

      talc = MineralOccurrence.find_by!(source: "usgs_mrds", external_id: "10045678")
      assert_equal "Hamilton Skagit Talc-Soapstone", talc.name
      assert_equal "Metamorphic Ultramafic", talc.deposit_type
      assert_includes talc.commodities, "Talc-Soapstone"
      assert_includes talc.commodities, "Magnesite"
      assert_includes talc.minerals, "Talc"
      assert_includes talc.minerals, "Dolomite"
      assert_in_delta 48.5236, talc.latitude, 0.0001
      assert_in_delta(-121.9892, talc.longitude, 0.0001)
      assert_equal "Washington", talc.raw_metadata["state"]
      assert_includes talc.ceramic_highlights, "talc-soapstone"

      # Pure Silver/Gold occurrence is filtered out by default ceramic commodities list
      assert_nil MineralOccurrence.find_by(source: "usgs_mrds", external_id: "10045679")
    end

    test "parses GeoJSON WFS response cleanly and persists MineralOccurrence records" do
      geojson_body = {
        type: "FeatureCollection",
        features: [
          {
            type: "Feature",
            id: "mrds.2009001",
            geometry: {
              type: "Point",
              coordinates: [ -117.1770, 47.5150 ]
            },
            properties: {
              dep_id: "2009001",
              site_name: "Freeman Residual Kaolin Pit",
              commod1: "Kaolin",
              commod2: "Silica",
              ore: "Kaolinite, Halloysite",
              gangue: "Quartz",
              dep_type: "Residual Clay",
              state: "Washington",
              county: "Spokane"
            }
          },
          {
            type: "Feature",
            id: "mrds.2009002",
            geometry: {
              type: "Point",
              coordinates: [ -117.6410, 48.3015 ]
            },
            properties: {
              dep_id: "2009002",
              site_name: "Chewelah Feldspar Pegmatite",
              commod1: "Feldspar",
              commod2: "Quartz",
              ore: "Microcline, Albite",
              dep_type: "Granitic Pegmatite"
            }
          }
        ]
      }.to_json

      stub = stub_request(:get, MRDS_URL)
        .with(query: hash_including("service" => "WFS", "typeName" => "mrds"))
        .to_return(status: 200, body: geojson_body, headers: { "Content-Type" => "application/json" })

      results = Clients::UsgsMrdsClient.search_nearby(lat: 47.55, lng: -117.15, radius_km: 100)

      assert_requested stub, times: 1
      assert_equal 2, results.size

      kaolin = MineralOccurrence.find_by!(source: "usgs_mrds", external_id: "2009001")
      assert_equal "Freeman Residual Kaolin Pit", kaolin.name
      assert_equal [ "Kaolin", "Silica" ], kaolin.commodities
      assert_includes kaolin.minerals, "Kaolinite"
      assert_in_delta 47.5150, kaolin.latitude, 0.0001
      assert_in_delta(-117.1770, kaolin.longitude, 0.0001)
    end

    test "returns cached PostGIS records within radius without HTTP call and supports force_refresh" do
      cached = MineralOccurrence.create!(
        source: "usgs_mrds",
        external_id: "3001001",
        name: "Cached Enumclaw Andesite",
        commodities: [ "Iron", "Silica" ],
        minerals: [ "Plagioclase", "Magnetite" ],
        deposit_type: "Volcanic Flow",
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG
      )

      stub = stub_request(:get, MRDS_URL)
        .with(query: hash_including("service" => "WFS"))
        .to_return(
          status: 200,
          body: {
            type: "FeatureCollection",
            features: [
              {
                type: "Feature",
                geometry: { type: "Point", coordinates: [ TACOMA_LNG, TACOMA_LAT ] },
                properties: {
                  dep_id: "3001001",
                  site_name: "Refreshed Enumclaw Andesite Quarry",
                  commod1: "Iron",
                  commod2: "Silica",
                  dep_type: "Volcanic Quarry"
                }
              }
            ]
          }.to_json,
          headers: { "Content-Type" => "application/json" }
        )

      from_cache = Clients::UsgsMrdsClient.search_nearby(lat: TACOMA_LAT + 0.01, lng: TACOMA_LNG, radius_km: 50)
      assert_equal [ cached.id ], from_cache.map(&:id)
      assert_not_requested stub

      refreshed = Clients::UsgsMrdsClient.search_nearby(
        lat: TACOMA_LAT,
        lng: TACOMA_LNG,
        radius_km: 50,
        force_refresh: true
      )
      assert_requested stub, times: 1
      assert_equal [ cached.id ], refreshed.map(&:id)
      assert_equal "Refreshed Enumclaw Andesite Quarry", cached.reload.name
      assert_equal 1, MineralOccurrence.by_source("usgs_mrds").count
    end

    test "retries on transient 503/timeout and degrades gracefully to empty array on sustained timeout or WFS exception" do
      geojson_ok = {
        type: "FeatureCollection",
        features: [
          {
            type: "Feature",
            geometry: { type: "Point", coordinates: [ -123.285, 47.468 ] },
            properties: {
              dep_id: "4001001",
              site_name: "Lake Cushman Pyrolusite",
              commod1: "Manganese",
              ore: "Pyrolusite"
            }
          }
        ]
      }.to_json

      retry_stub = stub_request(:get, MRDS_URL)
        .with(query: hash_including("service" => "WFS"))
        .to_return(
          { status: 503, body: "Temporarily unavailable" },
          { status: 200, body: geojson_ok, headers: { "Content-Type" => "application/json" } }
        )

      recovered = Clients::UsgsMrdsClient.new(retry_delay: 0.0)
        .search_nearby(lat: 47.47, lng: -123.28, radius_km: 25)
      assert_requested retry_stub, times: 2
      assert_equal [ "4001001" ], recovered.map(&:external_id)

      WebMock.reset!
      timeout_stub = stub_request(:get, MRDS_URL)
        .with(query: hash_including("service" => "WFS"))
        .to_timeout

      assert_equal [], Clients::UsgsMrdsClient.new(retry_delay: 0.0)
        .search_nearby(lat: 42.5, lng: -118.4, radius_km: 25)
      assert_requested timeout_stub, times: 3

      assert_raises(Clients::UsgsMrdsClient::NetworkError) do
        Clients::UsgsMrdsClient.new(retry_delay: 0.0)
          .search_nearby!(lat: 42.5, lng: -118.4, radius_km: 25)
      end

      WebMock.reset!
      exception_xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <ServiceExceptionReport>
          <ServiceException>msWFSGetFeature(): Invalid bounding box</ServiceException>
        </ServiceExceptionReport>
      XML
      stub_request(:get, MRDS_URL)
        .with(query: hash_including("service" => "WFS"))
        .to_return(status: 200, body: exception_xml, headers: { "Content-Type" => "text/xml" })

      assert_equal [], Clients::UsgsMrdsClient.search_nearby(lat: 42.5, lng: -118.4, radius_km: 25)
      assert_raises(Clients::UsgsMrdsClient::Error) do
        Clients::UsgsMrdsClient.search_nearby!(lat: 42.5, lng: -118.4, radius_km: 25)
      end
    end

    test "rejects invalid coordinates before making any HTTP calls" do
      stub = stub_request(:get, /mrdata\.usgs\.gov/)

      assert_equal [], Clients::UsgsMrdsClient.search_nearby(lat: nil, lng: -122.4)
      assert_equal [], Clients::UsgsMrdsClient.search_nearby(lat: 99.0, lng: -122.4)
      assert_equal [], Clients::UsgsMrdsClient.search_nearby(lat: 47.2, lng: 185.0)
      assert_not_requested stub
    end
  end
end
