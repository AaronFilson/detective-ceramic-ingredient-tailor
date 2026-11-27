# frozen_string_literal: true

class RegionalSyncsController < ApplicationController
  DEFAULT_RADIUS_KM = 150
  MIN_RADIUS_KM = 25
  MAX_RADIUS_KM = 500

  # POST /regional_sync
  def create
    setting = current_studio_setting
    lat = resolve_coordinate(params[:lat], setting.default_lat.to_f, -90.0..90.0)
    lng = resolve_coordinate(params[:lng], setting.default_lng.to_f, -180.0..180.0)

    if lat.nil? || lng.nil?
      return respond_invalid_coordinates(setting)
    end

    radius_km = parse_radius_km(params[:radius_km])

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

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "regional_sync_card",
          partial: "setup_wizard/regional_sync_card",
          locals: {
            studio_setting: setting,
            lat: lat,
            lng: lng,
            radius_km: radius_km
          }
        )
      end
      format.json do
        render json: {
          status: setting.regional_sync_status,
          summary: setting.regional_sync_summary,
          lat: lat,
          lng: lng,
          radius_km: radius_km
        }, status: :accepted
      end
      format.html do
        redirect_back fallback_location: setup_path(step: 4),
          notice: "Queued regional geochemical atlas sync (#{radius_km} km radius)."
      end
    end
  end

  private

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
        render turbo_stream: turbo_stream.replace(
          "regional_sync_card",
          partial: "setup_wizard/regional_sync_card",
          locals: {
            studio_setting: setting,
            sync_error: error_message
          }
        ), status: :unprocessable_entity
      end
      format.json { render json: { error: error_message }, status: :unprocessable_entity }
      format.html { redirect_back fallback_location: setup_path(step: 4), alert: error_message }
    end
  end
end
