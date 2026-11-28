# frozen_string_literal: true

class RegionalSyncsController < ApplicationController
  rate_limit to: 3, within: 30.minutes, only: :create

  DEFAULT_RADIUS_KM = 150
  MIN_RADIUS_KM = 25
  MAX_RADIUS_KM = 500
  TILE_DEDUPE_TTL = 15.minutes

  # POST /regional_sync
  def create
    setting = current_studio_setting
    lat = resolve_coordinate(params[:lat], setting.default_lat.to_f, -90.0..90.0)
    lng = resolve_coordinate(params[:lng], setting.default_lng.to_f, -180.0..180.0)

    if lat.nil? || lng.nil?
      return respond_invalid_coordinates(setting)
    end

    radius_km = parse_radius_km(params[:radius_km])

    if tile_recently_synced?(lat: lat, lng: lng, radius_km: radius_km)
      setting.update!(
        regional_sync_status: "synced",
        regional_synced_at: Time.current,
        regional_sync_summary: "Regional atlas already synced recently within #{radius_km} km (#{format('%.2f, %.2f', lat, lng)})."
      )
      return respond_sync_accepted(
        setting: setting,
        lat: lat,
        lng: lng,
        radius_km: radius_km,
        deduped: true
      )
    end

    mark_tile_synced!(lat: lat, lng: lng, radius_km: radius_km)

    setting.update!(
      regional_sync_status: "queued",
      regional_sync_summary: "Queued regional sync within #{radius_km} km (#{format('%.2f, %.2f', lat, lng)})..."
    )

    RegionalAtlasSyncJob.perform_later(
      setting.id,
      lat: lat,
      lng: lng,
      radius_km: radius_km
    )

    respond_sync_accepted(
      setting: setting,
      lat: lat,
      lng: lng,
      radius_km: radius_km,
      deduped: false
    )
  end

  private

  def sync_dedupe_enabled?
    !Rails.env.test? || ENV["TEST_SYNC_DEDUPE"] == "1"
  end

  def tile_cache_key(lat:, lng:, radius_km:)
    "regional_sync:tile:#{(lat * 2).round}:#{(lng * 2).round}:#{radius_km}"
  end

  def tile_recently_synced?(lat:, lng:, radius_km:)
    return false unless sync_dedupe_enabled?

    Rails.cache.exist?(tile_cache_key(lat: lat, lng: lng, radius_km: radius_km))
  end

  def mark_tile_synced!(lat:, lng:, radius_km:)
    return unless sync_dedupe_enabled?

    Rails.cache.write(
      tile_cache_key(lat: lat, lng: lng, radius_km: radius_km),
      Time.current.iso8601,
      expires_in: TILE_DEDUPE_TTL
    )
  end

  def respond_sync_accepted(setting:, lat:, lng:, radius_km:, deduped:)
    notice_message =
      if deduped
        "Regional geochemical atlas already synced recently for this #{radius_km} km area."
      else
        "Queued regional geochemical atlas sync (#{radius_km} km radius)."
      end

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: regional_sync_turbo_streams(
          studio_setting: setting,
          lat: lat,
          lng: lng,
          radius_km: radius_km
        )
      end
      format.json do
        render json: {
          status: setting.regional_sync_status,
          summary: setting.regional_sync_summary,
          deduped: deduped,
          lat: lat,
          lng: lng,
          radius_km: radius_km
        }, status: :accepted
      end
      format.html do
        redirect_back fallback_location: setup_path(step: 4), notice: notice_message
      end
    end
  end

  def resolve_coordinate(raw_value, fallback, range)
    return fallback if raw_value.blank?

    num = Float(raw_value)
    return nil if num.nan? || num.infinite? || !range.cover?(num)

    num
  rescue ArgumentError, TypeError
    nil
  end

  def parse_radius_km(raw_value)
    return DEFAULT_RADIUS_KM if raw_value.blank?

    num = Float(raw_value)
    return DEFAULT_RADIUS_KM if num.nan? || num.infinite?

    clamped = num.clamp(MIN_RADIUS_KM, MAX_RADIUS_KM)
    clamped == clamped.to_i ? clamped.to_i : clamped.round(1)
  rescue ArgumentError, TypeError
    DEFAULT_RADIUS_KM
  end

  def respond_invalid_coordinates(setting)
    error_message = "Valid latitude (-90..90) and longitude (-180..180) are required to sync regional data."
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: regional_sync_turbo_streams(
          studio_setting: setting,
          sync_error: error_message
        ), status: :unprocessable_entity
      end
      format.json { render json: { error: error_message }, status: :unprocessable_entity }
      format.html { redirect_back fallback_location: setup_path(step: 4), alert: error_message }
    end
  end

  def regional_sync_turbo_streams(**locals)
    %w[regional_sync_card wizard_regional_sync_card].map do |card_id|
      turbo_stream.replace(
        card_id,
        partial: "setup_wizard/regional_sync_card",
        locals: locals.merge(dom_id: card_id)
      )
    end
  end
end
