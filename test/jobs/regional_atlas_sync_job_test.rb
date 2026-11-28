# frozen_string_literal: true

require "test_helper"

class RegionalAtlasSyncJobTest < ActiveJob::TestCase
  TACOMA_LAT = 47.2529
  TACOMA_LNG = -122.4443
  MRDS_URL = "https://mrdata.usgs.gov/services/mrds"
  SCIENCEBASE_CATALOG_PATTERN = %r{\Ahttps://www\.sciencebase\.gov/catalog/items}
  SCIENCEBASE_CSV_URL = "https://www.sciencebase.gov/catalog/file/get/pnw-1?name=pnw_ngdb.csv"
  GEOROC_SAMPLES_URL = "https://api-test.georoc.eu/api/v1/queries/samples"

  setup do
    WebMock.reset!
    StudioSetting.delete_all
    MineralOccurrence.delete_all
    ReferenceAssay.delete_all
    @prev_georoc_key = ENV["GEOROC_API_KEY"]
    @prev_georoc_url = ENV["GEOROC_BASE_URL"]
    ENV["GEOROC_API_KEY"] = nil
    ENV["GEOROC_BASE_URL"] = nil
  end

  teardown do
    ENV["GEOROC_API_KEY"] = @prev_georoc_key
    ENV["GEOROC_BASE_URL"] = @prev_georoc_url
  end

  test "syncs USGS MRDS deposits and ScienceBase assays for US coordinates and updates StudioSetting" do
    setting = StudioSetting.current
    mrds_stub = stub_mrds_response(
      features: [
        {
          type: "Feature",
          geometry: { type: "Point", coordinates: [ -121.9915, 47.2043 ] },
          properties: {
            dep_id: "99001",
            site_name: "Enumclaw Andesite Deposit",
            commod1: "Iron",
            commod2: "Silica"
          }
        }
      ]
    )
    sb_catalog_stub = stub_sciencebase_catalog(csv_url: SCIENCEBASE_CSV_URL)
    sb_csv_stub = stub_request(:get, SCIENCEBASE_CSV_URL).to_return(
      status: 200,
      headers: { "Content-Type" => "text/csv" },
      body: <<~CSV
        LAB_ID,LATITUDE,LONGITUDE,ROCK_TYPE,SIO2,AL2O3,FE2O3,CAO,MGO,NA2O,K2O,TIO2,P2O5,MNO,LOI
        SYNC-WA-1,47.2529,-122.4443,glacial_clay,58.5,17.5,6.2,3.1,2.4,2.3,2.1,0.8,0.2,0.1,6.8
        SYNC-WA-2,47.4000,-122.3000,alluvial_clay,60.0,16.8,5.8,2.9,2.1,2.4,2.2,0.8,0.2,0.1,6.7
        SYNC-TX-OUT,30.2672,-97.7431,shale,61.0,16.5,5.0,4.5,2.0,1.5,2.5,0.7,0.2,0.1,6.0
      CSV
    )
    georoc_stub = stub_request(:get, /georoc\.eu/)

    result = RegionalAtlasSyncJob.perform_now(
      setting.id,
      lat: TACOMA_LAT,
      lng: TACOMA_LNG,
      radius_km: 150
    )

    assert_requested mrds_stub, times: 1
    assert_requested sb_catalog_stub, times: 1
    assert_requested sb_csv_stub, times: 1
    assert_not_requested georoc_stub

    setting.reload
    assert_equal "synced", setting.regional_sync_status
    assert_not_nil setting.regional_synced_at
    assert_equal "Synced 1 MRDS deposit & 2 USGS assays within 150 km", setting.regional_sync_summary

    assert_equal "synced", result[:status]
    assert_equal 1, result[:mrds_count]
    assert_equal 2, result[:usgs_count]
    assert_equal 0, result[:georoc_count]
    assert MineralOccurrence.exists?(source: "usgs_mrds", external_id: "99001")
    assert ReferenceAssay.exists?(source: "usgs_ngdb", external_id: "SYNC-WA-1")
    assert ReferenceAssay.exists?(source: "usgs_ngdb", external_id: "SYNC-WA-2")
    assert_not ReferenceAssay.exists?(source: "usgs_ngdb", external_id: "SYNC-TX-OUT")
  end

  test "queries and imports GEOROC 2.0 samples when GEOROC_API_KEY is configured" do
    ENV["GEOROC_API_KEY"] = "test-georoc-sync-key"
    setting = StudioSetting.current

    stub_mrds_response(features: [])
    stub_sciencebase_catalog(csv_url: nil)

    georoc_stub = stub_request(:get, GEOROC_SAMPLES_URL)
      .with(
        headers: { "DIGIS-API-ACCESSKEY" => "test-georoc-sync-key" },
        query: hash_including("latitude_min", "latitude_max", "longitude_min", "longitude_max")
      )
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          data: [
            {
              "sample_name" => "GEOROC-WA-1",
              "rock_name" => "ANDESITE",
              "latitude" => 47.26,
              "longitude" => -122.41,
              "SiO2" => 58.2,
              "Al2O3" => 17.4,
              "Fe2O3" => 6.8,
              "CaO" => 6.4,
              "MgO" => 3.5,
              "Na2O" => 3.7,
              "K2O" => 1.8,
              "TiO2" => 0.9,
              "P2O5" => 0.2,
              "MnO" => 0.1,
              "LOI" => 1.0,
              "BaO" => 0.15,
              "Rb_ppm" => 95.0
            }
          ]
        }.to_json
      )

    result = RegionalAtlasSyncJob.perform_now(setting.id, radius_km: 100)

    assert_requested georoc_stub, times: 1
    setting.reload
    assert_equal "synced", setting.regional_sync_status
    assert_equal 1, result[:georoc_count]
    assert_includes setting.regional_sync_summary, "1 GEOROC assay"
    assert_includes setting.regional_sync_summary, "within 100 km"

    imported = ReferenceAssay.find_by!(source: "georoc", external_id: "GEOROC-WA-1")
    assert_in_delta 0.15, imported.minor_oxides["BaO"], 0.001
    assert_in_delta 95.0, imported.trace_elements_ppm["Rb"], 0.1
  end

  test "skips USGS ScienceBase cleanly for non-US coordinates without failing" do
    setting = StudioSetting.current
    mrds_stub = stub_mrds_response(features: [])
    sb_stub = stub_request(:get, SCIENCEBASE_CATALOG_PATTERN)

    result = RegionalAtlasSyncJob.perform_now(
      setting.id,
      lat: 51.8000,
      lng: -1.2000,
      radius_km: 200
    )

    assert_requested mrds_stub, times: 1
    assert_not_requested sb_stub

    setting.reload
    assert_equal "synced", setting.regional_sync_status
    assert_equal "Synced 0 MRDS deposits within 200 km", setting.regional_sync_summary
    assert_equal "synced", result[:status]
  end

  test "recovers gracefully when USGS ScienceBase catalog returns 500 while MRDS succeeds" do
    setting = StudioSetting.current
    stub_mrds_response(
      features: [
        {
          type: "Feature",
          geometry: { type: "Point", coordinates: [ -122.20, 47.22 ] },
          properties: { dep_id: "99009", site_name: "Puget Kaolin Pit", commod1: "Kaolin" }
        }
      ]
    )
    stub_request(:get, SCIENCEBASE_CATALOG_PATTERN).to_return(status: 500, body: "Upstream outage")

    result = RegionalAtlasSyncJob.perform_now(setting.id, lat: TACOMA_LAT, lng: TACOMA_LNG, radius_km: 150)

    setting.reload
    assert_equal "synced", setting.regional_sync_status
    assert_equal 1, result[:mrds_count]
    assert_equal 0, result[:usgs_count]
    assert_equal "Synced 1 MRDS deposit & 0 USGS assays within 150 km", setting.regional_sync_summary
  end

  test "marks StudioSetting as error without crashing queue on unexpected failures" do
    setting = StudioSetting.current

    # Out-of-bounds coordinates trigger clean error status without raising
    invalid_result = RegionalAtlasSyncJob.perform_now(setting.id, lat: 145.0, lng: TACOMA_LNG)
    setting.reload
    assert_equal "error", invalid_result[:status]
    assert_equal "error", setting.regional_sync_status
    assert_includes setting.regional_sync_summary, "Invalid coordinates"

    # Unexpected runtime exception from a client marks error cleanly and does not raise
    original = Clients::UsgsMrdsClient.method(:search_nearby)
    Clients::UsgsMrdsClient.define_singleton_method(:search_nearby) { |**| raise RuntimeError, "unexpected socket panic" }
    begin
      err_result = RegionalAtlasSyncJob.perform_now(setting.id, lat: TACOMA_LAT, lng: TACOMA_LNG)
    ensure
      Clients::UsgsMrdsClient.define_singleton_method(:search_nearby, original)
    end

    setting.reload
    assert_equal "error", err_result[:status]
    assert_equal "error", setting.regional_sync_status
    assert_includes setting.regional_sync_summary, "unexpected socket panic"
  end

  test "writes tile dedupe cache key after successful sync and leaves cache untouched on failure" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    setting = StudioSetting.current
    tile_key = RegionalAtlasSyncJob.tile_cache_key(lat: TACOMA_LAT, lng: TACOMA_LNG, radius_km: 150)

    original = Clients::UsgsMrdsClient.method(:search_nearby)
    Clients::UsgsMrdsClient.define_singleton_method(:search_nearby) { |**| raise RuntimeError, "upstream timeout" }
    begin
      err_result = RegionalAtlasSyncJob.perform_now(setting.id, lat: TACOMA_LAT, lng: TACOMA_LNG, radius_km: 150)
    ensure
      Clients::UsgsMrdsClient.define_singleton_method(:search_nearby, original)
    end

    assert_equal "error", err_result[:status]
    assert_not Rails.cache.exist?(tile_key), "Failed sync must never poison the 15-minute tile cache"

    stub_mrds_response(features: [])
    stub_sciencebase_catalog(csv_url: nil)

    ok_result = RegionalAtlasSyncJob.perform_now(setting.id, lat: TACOMA_LAT, lng: TACOMA_LNG, radius_km: 150)
    assert_equal "synced", ok_result[:status]
    assert Rails.cache.exist?(tile_key), "Successful sync must write the shared tile dedupe cache key"
  ensure
    Rails.cache = original_cache
  end

  private

  def stub_mrds_response(features:)
    stub_request(:get, MRDS_URL)
      .with(query: hash_including("service" => "WFS", "typeName" => "mrds-high"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { type: "FeatureCollection", features: features }.to_json
      )
  end

  def stub_sciencebase_catalog(csv_url:)
    items =
      if csv_url
        [
          {
            id: "pnw-1",
            title: "USGS PNW Geochemistry",
            files: [ { name: "pnw_ngdb.csv", contentType: "text/csv", url: csv_url } ]
          }
        ]
      else
        []
      end

    stub_request(:get, SCIENCEBASE_CATALOG_PATTERN)
      .with(query: hash_including("format" => "json"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { items: items }.to_json
      )
  end
end
