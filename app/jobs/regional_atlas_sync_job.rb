# frozen_string_literal: true

require "csv"
require "stringio"

class RegionalAtlasSyncJob < ApplicationJob
  queue_as :default

  DEFAULT_RADIUS_KM = 150.0
  MIN_RADIUS_KM = 25.0
  MAX_RADIUS_KM = 500.0
  MRDS_MAX_RADIUS_KM = 100.0
  KM_PER_DEGREE_LAT = 111.32
  GEOROC_LIMIT = 100
  GEOROC_MAX_PAGES = 2
  TILE_DEDUPE_TTL = 15.minutes

  def self.tile_cache_key(lat:, lng:, radius_km: DEFAULT_RADIUS_KM)
    norm_lat = Float(lat)
    norm_lng = Float(lng)
    norm_radius = Float(radius_km).clamp(MIN_RADIUS_KM, MAX_RADIUS_KM)
    radius_token = norm_radius == norm_radius.to_i ? norm_radius.to_i : norm_radius.round(1)
    "regional_sync:tile:#{(norm_lat * 2).round}:#{(norm_lng * 2).round}:#{radius_token}"
  end

  def perform(studio_setting_id = nil, lat: nil, lng: nil, radius_km: DEFAULT_RADIUS_KM)
    setting = resolve_setting(studio_setting_id)
    return nil unless setting

    effective_lat = parse_float(lat) || setting.default_lat.to_f
    effective_lng = parse_float(lng) || setting.default_lng.to_f
    unless valid_coordinates?(effective_lat, effective_lng)
      mark_error!(setting, "Invalid coordinates for regional sync.")
      return { status: "error", summary: setting.regional_sync_summary }
    end

    effective_radius_km = normalize_radius(radius_km)
    radius_label = format_radius(effective_radius_km)
    bbox = compute_bounding_box(effective_lat, effective_lng, effective_radius_km)
    bbox_string = format("%.4f,%.4f,%.4f,%.4f", bbox[:min_lat], bbox[:min_lng], bbox[:max_lat], bbox[:max_lng])

    setting.update!(
      regional_sync_status: "running",
      regional_sync_summary: "Syncing regional deposits & assays within #{radius_label} km..."
    )

    mrds_records = Array(
      Clients::UsgsMrdsClient.search_nearby(
        lat: effective_lat,
        lng: effective_lng,
        radius_km: [ effective_radius_km, MRDS_MAX_RADIUS_KM ].min,
        force_refresh: true
      )
    )
    mrds_count = mrds_records.size

    us_region = us_coordinates?(effective_lat, effective_lng)
    usgs_count = us_region ? sync_usgs_sciencebase(bbox_string) : 0

    georoc_enabled = Clients::GeorocClient.configured?
    georoc_stats = georoc_enabled ? sync_georoc(bbox) : { fetched: 0, imported: 0 }

    summary = build_summary(
      mrds_count: mrds_count,
      usgs_count: usgs_count,
      georoc_stats: georoc_stats,
      radius_label: radius_label,
      us_region: us_region,
      georoc_enabled: georoc_enabled
    )

    setting.update!(
      regional_sync_status: "synced",
      regional_synced_at: Time.current,
      regional_sync_summary: summary
    )

    Rails.cache.write(
      self.class.tile_cache_key(lat: effective_lat, lng: effective_lng, radius_km: effective_radius_km),
      Time.current.iso8601,
      expires_in: TILE_DEDUPE_TTL
    )

    {
      status: "synced",
      mrds_count: mrds_count,
      usgs_count: usgs_count,
      georoc_count: georoc_stats[:imported].positive? ? georoc_stats[:imported] : georoc_stats[:fetched],
      radius_km: effective_radius_km,
      bbox: bbox_string,
      summary: summary
    }
  rescue StandardError => e
    Rails.logger.error("[RegionalAtlasSyncJob] Unexpected sync failure: #{e.class}: #{e.message}")
    mark_error!(setting, "Sync failed: #{e.message.to_s.strip.truncate(160)}") if setting
    { status: "error", error: e.message }
  end

  private

  def resolve_setting(studio_setting_id)
    if studio_setting_id.present?
      StudioSetting.find_by(id: studio_setting_id)
    else
      StudioSetting.current
    end
  end

  def sync_usgs_sciencebase(bbox_string)
    result = Ingestion::UsgsSciencebaseFetcher.call(bbox: bbox_string)
    result&.imported.to_i
  rescue Ingestion::UsgsSciencebaseFetcher::Error => e
    Rails.logger.warn("[RegionalAtlasSyncJob] USGS ScienceBase fetch skipped (#{bbox_string}): #{e.message}")
    0
  end

  def sync_georoc(bbox)
    records = Array(
      Clients::GeorocClient.query_samples(
        bbox: {
          min_lat: bbox[:min_lat],
          max_lat: bbox[:max_lat],
          min_lng: bbox[:min_lng],
          max_lng: bbox[:max_lng]
        },
        limit: GEOROC_LIMIT,
        max_pages: GEOROC_MAX_PAGES
      )
    )
    imported = import_georoc_records(records)
    { fetched: records.size, imported: imported }
  rescue Clients::GeorocClient::Error => e
    Rails.logger.warn("[RegionalAtlasSyncJob] GEOROC query skipped: #{e.message}")
    { fetched: 0, imported: 0 }
  end

  def import_georoc_records(records)
    return 0 if records.empty?

    headers = records.flat_map { |r| r.is_a?(Hash) ? r.keys.map(&:to_s) : [] }.uniq
    return 0 if headers.empty?

    csv_body = CSV.generate do |csv|
      csv << headers
      records.each do |record|
        next unless record.is_a?(Hash)

        csv << headers.map do |header|
          val = record.key?(header) ? record[header] : record[header.to_sym]
          val.is_a?(Hash) || val.is_a?(Array) ? val.to_json : val
        end
      end
    end

    Ingestion::GeorocCsvImporter.new(StringIO.new(csv_body), bulk: true).call.imported
  rescue StandardError => e
    Rails.logger.warn("[RegionalAtlasSyncJob] GEOROC record persistence skipped: #{e.message}")
    0
  end

  def build_summary(mrds_count:, usgs_count:, georoc_stats:, radius_label:, us_region:, georoc_enabled:)
    parts = [ "#{mrds_count} MRDS #{pluralize_noun(mrds_count, 'deposit')}" ]
    parts << "#{usgs_count} USGS #{pluralize_noun(usgs_count, 'assay')}" if us_region

    if georoc_enabled
      if georoc_stats[:imported].positive?
        parts << "#{georoc_stats[:imported]} GEOROC #{pluralize_noun(georoc_stats[:imported], 'assay')}"
      elsif georoc_stats[:fetched].positive?
        parts << "#{georoc_stats[:fetched]} GEOROC #{pluralize_noun(georoc_stats[:fetched], 'sample')}"
      end
    end

    counts_text =
      if parts.length == 1
        parts.first
      elsif parts.length == 2
        "#{parts[0]} & #{parts[1]}"
      else
        "#{parts[0..-2].join(', ')} & #{parts.last}"
      end

    "Synced #{counts_text} within #{radius_label} km"
  end

  def pluralize_noun(count, singular)
    count == 1 ? singular : "#{singular}s"
  end

  def compute_bounding_box(lat, lng, radius_km)
    lat_delta = radius_km / KM_PER_DEGREE_LAT
    cos_lat = [ Math.cos(lat * Math::PI / 180.0).abs, 0.01 ].max
    lng_delta = radius_km / (KM_PER_DEGREE_LAT * cos_lat)

    {
      min_lat: [ lat - lat_delta, -90.0 ].max.round(4),
      min_lng: [ lng - lng_delta, -180.0 ].max.round(4),
      max_lat: [ lat + lat_delta, 90.0 ].min.round(4),
      max_lng: [ lng + lng_delta, 180.0 ].min.round(4)
    }
  end

  # Covers CONUS, Alaska, Hawaii, and US Caribbean territories.
  def us_coordinates?(lat, lng)
    lat.between?(17.5, 72.0) && lng.between?(-180.0, -64.0)
  end

  def valid_coordinates?(lat, lng)
    lat.is_a?(Numeric) && lng.is_a?(Numeric) &&
      lat.finite? && lng.finite? &&
      lat.between?(-90.0, 90.0) && lng.between?(-180.0, 180.0)
  end

  def normalize_radius(value)
    parsed = parse_float(value) || DEFAULT_RADIUS_KM
    parsed.clamp(MIN_RADIUS_KM, MAX_RADIUS_KM)
  end

  def format_radius(radius_km)
    radius_km == radius_km.to_i ? radius_km.to_i.to_s : format("%.1f", radius_km)
  end

  def parse_float(value)
    return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)

    num = Float(value)
    return nil if num.nan? || num.infinite?

    num
  rescue ArgumentError, TypeError
    nil
  end

  def mark_error!(setting, message)
    setting.update_columns(
      regional_sync_status: "error",
      regional_sync_summary: message.to_s.truncate(255),
      updated_at: Time.current
    )
  end
end
