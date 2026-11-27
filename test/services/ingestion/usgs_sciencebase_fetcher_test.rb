# frozen_string_literal: true

require "test_helper"
require "stringio"

module Ingestion
  class UsgsSciencebaseFetcherTest < ActiveSupport::TestCase
    CATALOG_URL_PATTERN = %r{\Ahttps://www\.sciencebase\.gov/catalog/items}
    CSV_URL_1 = "https://www.sciencebase.gov/catalog/file/get/item-1?name=ngdb_pnw.csv"
    CSV_URL_2 = "https://www.sciencebase.gov/catalog/file/get/item-2?name=ngdb_extra.csv"

    setup do
      WebMock.reset!
      ReferenceAssay.delete_all
    end

    test "discovers ScienceBase CSV attachments, filters to WA/PNW bbox, and bulk-imports via upsert_all" do
      catalog_body = {
        items: [
          {
            id: "item-1",
            title: "USGS National Geochemical Database - Clay & Rock",
            files: [
              { name: "readme.pdf", contentType: "application/pdf", url: "https://www.sciencebase.gov/catalog/file/get/item-1?name=readme.pdf" },
              { name: "ngdb_pnw.csv", contentType: "text/csv", url: CSV_URL_1 }
            ]
          },
          {
            id: "item-2",
            title: "Supplemental Western US Geochemistry",
            webLinks: [
              { uri: CSV_URL_2 }
            ]
          }
        ]
      }.to_json

      csv_1 = <<~CSV
        LAB_ID,LATITUDE,LONGITUDE,ROCK_TYPE,SIO2,AL2O3,FE2O3,CAO,MGO,NA2O,K2O,TIO2,P2O5,MNO,LOI
        SB-WA-1,47.2529,-122.4443,glacial_clay,58.5,17.5,6.2,3.1,2.4,2.3,2.1,0.8,0.2,0.1,6.8
        SB-WA-2,47.6062,-122.3321,marine_clay,56.8,18.2,6.8,3.6,2.8,2.5,2.3,0.9,0.2,0.1,5.8
        SB-TX-OUT,30.2672,-97.7431,shale,61.0,16.5,5.0,4.5,2.0,1.5,2.5,0.7,0.2,0.1,6.0
      CSV

      csv_2 = <<~CSV
        LAB_ID,LAT,LNG,ROCK_TYPE,SIO2,AL2O3,FE2O3,CAO,MGO,NA2O,K2O,TIO2,P2O5,MNO,LOI
        SB-OR-1,45.5152,-122.6784,alluvial_clay,60.2,16.8,5.8,2.9,2.1,2.4,2.2,0.8,0.2,0.1,6.5
        SB-WA-BAD,47.3000,-122.4000,clay,,16.0,5.0,2.0,1.0,1.0,1.0,0.5,0.1,0.1,5.0
      CSV

      catalog_stub = stub_request(:get, CATALOG_URL_PATTERN)
        .with(query: hash_including("format" => "json"))
        .to_return(status: 200, body: catalog_body, headers: { "Content-Type" => "application/json" })

      stub_request(:get, CSV_URL_1).to_return(status: 200, body: csv_1, headers: { "Content-Type" => "text/csv" })
      stub_request(:get, CSV_URL_2).to_return(status: 200, body: csv_2, headers: { "Content-Type" => "text/csv" })

      result = Ingestion::UsgsSciencebaseFetcher.call(region: "PNW")

      assert_requested catalog_stub, times: 1
      assert_equal 2, result.files_processed
      assert_equal [ CSV_URL_1, CSV_URL_2 ], result.discovered_urls
      assert_equal 4, result.matched_rows
      assert_equal 1, result.filtered_out_rows
      assert_equal 3, result.imported
      assert_equal 3, result.created
      assert_equal 0, result.updated
      assert_equal 1, result.skipped

      assert ReferenceAssay.exists?(source: "usgs_ngdb", external_id: "SB-WA-1")
      assert ReferenceAssay.exists?(source: "usgs_ngdb", external_id: "SB-WA-2")
      assert ReferenceAssay.exists?(source: "usgs_ngdb", external_id: "SB-OR-1")
      assert_not ReferenceAssay.exists?(source: "usgs_ngdb", external_id: "SB-TX-OUT")

      wa_assay = ReferenceAssay.find_by!(source: "usgs_ngdb", external_id: "SB-WA-1")
      assert_in_delta 47.2529, wa_assay.latitude, 0.0001
      assert_in_delta(-122.4443, wa_assay.longitude, 0.0001)
      assert_in_delta 100.0, wa_assay.oxides.values.sum, 0.01

      # Re-running the same fetch updates in place idempotently without duplicates
      second = Ingestion::UsgsSciencebaseFetcher.call(region: "PNW")
      assert_equal 3, second.imported
      assert_equal 0, second.created
      assert_equal 3, second.updated
      assert_equal 3, ReferenceAssay.by_source("usgs_ngdb").count
    end

    test "supports custom min_lat,min_lng,max_lat,max_lng bbox strings and rejects malformed bbox" do
      bbox = Ingestion::UsgsSciencebaseFetcher.parse_bbox("47.0,-123.0,48.0,-122.0")
      assert_equal({ min_lat: 47.0, min_lng: -123.0, max_lat: 48.0, max_lng: -122.0 }, bbox)

      wa_bbox = Ingestion::UsgsSciencebaseFetcher.parse_bbox("wa")
      assert_equal Ingestion::UsgsSciencebaseFetcher::REGION_BBOXES["WA"], wa_bbox

      assert_raises(ArgumentError) { Ingestion::UsgsSciencebaseFetcher.parse_bbox("MARS") }
      assert_raises(ArgumentError) { Ingestion::UsgsSciencebaseFetcher.parse_bbox("49.0,-122.0,45.0,-123.0") }
    end

    test "BaseCsvImporter bulk: true mode uses upsert_all cleanly and handles duplicate external_ids within a batch" do
      csv = <<~CSV
        LAB_ID,LATITUDE,LONGITUDE,ROCK_TYPE,SIO2,AL2O3,FE2O3,CAO,MGO,NA2O,K2O,TIO2,P2O5,MNO,LOI
        BULK-1,47.25,-122.44,glacial_clay,58.0,17.0,6.0,3.0,2.5,2.5,2.0,0.8,0.2,0.1,7.9
        BULK-2,47.30,-122.40,shale,62.0,18.0,5.0,1.5,1.8,1.5,2.8,0.9,0.1,0.1,6.3
        BULK-1,47.25,-122.44,glacial_clay,60.0,17.5,5.5,3.0,2.0,2.0,2.0,0.8,0.2,0.1,6.9
      CSV

      first = Ingestion::UsgsCsvImporter.new(StringIO.new(csv), bulk: true).call
      assert_equal 3, first.imported
      assert_equal 2, first.created
      assert_equal 1, first.updated
      assert_equal 0, first.skipped
      assert_equal 2, ReferenceAssay.by_source("usgs_ngdb").count

      bulk1 = ReferenceAssay.find_by!(source: "usgs_ngdb", external_id: "BULK-1")
      assert_in_delta 60.0, bulk1.oxides["SiO2"], 0.05
      assert_in_delta 47.25, bulk1.latitude, 0.0001
      assert_in_delta(-122.44, bulk1.longitude, 0.0001)

      # Re-run bulk mode updates existing records cleanly
      second = Ingestion::UsgsCsvImporter.new(StringIO.new(csv), bulk: true).call
      assert_equal 3, second.imported
      assert_equal 0, second.created
      assert_equal 3, second.updated
      assert_equal 2, ReferenceAssay.by_source("usgs_ngdb").count
    end

    test "handles per-file download failure gracefully while importing remaining CSV files" do
      stub_request(:get, CSV_URL_1).to_return(status: 500, body: "Upstream Error")
      stub_request(:get, CSV_URL_2).to_return(
        status: 200,
        body: "LAB_ID,LAT,LNG,ROCK_TYPE,SIO2,AL2O3,FE2O3,LOI\nSB-OK-1,47.25,-122.44,clay,60.0,18.0,5.0,7.0\n"
      )

      result = Ingestion::UsgsSciencebaseFetcher.call(
        region: "WA",
        csv_urls: [ CSV_URL_1, CSV_URL_2 ],
        retry_delay: 0.0
      )

      assert_equal 1, result.files_processed
      assert_equal 1, result.imported
      assert_equal 1, result.errors.size
      assert_equal CSV_URL_1, result.errors.first[:url]
      assert ReferenceAssay.exists?(source: "usgs_ngdb", external_id: "SB-OK-1")
    end
  end
end
