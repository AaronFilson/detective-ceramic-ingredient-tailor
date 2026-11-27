# frozen_string_literal: true

class MineralOccurrencesController < ApplicationController
  DEFAULT_RADIUS_KM = 50.0
  MIN_RADIUS_KM = 1.0
  MAX_RADIUS_KM = 500.0
  DEFAULT_LIMIT = 40
  MAX_LIMIT = 100
  CARD_LIMIT = 8
  CARD_MIN_DISPLAY_RADIUS_KM = 100.0

  # GET /mineral_occurrences.json?lat=...&lng=...&radius_km=50
  def index
    lat = parse_coordinate(params[:lat], -90.0, 90.0)
    lng = parse_coordinate(params[:lng], -180.0, 180.0)

    if lat.nil? || lng.nil?
      return respond_to do |format|
        format.json { render json: { error: "Valid lat and lng parameters are required" }, status: :bad_request }
        format.html { head :bad_request }
      end
    end

    radius_km = parse_radius_km(params[:radius_km])
    limit = parse_limit(params[:limit])
    occurrences = fetch_nearby(lat: lat, lng: lng, radius_km: radius_km, limit: limit, source: params[:source])

    respond_to do |format|
      format.json { render json: serialize_occurrences(occurrences, lat, lng) }
      format.html do
        render partial: "samples/mineral_occurrences_card",
          locals: { mineral_occurrences: occurrences.first(CARD_LIMIT), lat: lat, lng: lng }
      end
    end
  end

  # POST /mineral_occurrences/refresh
  def refresh
    lat = parse_coordinate(params[:lat], -90.0, 90.0)
    lng = parse_coordinate(params[:lng], -180.0, 180.0)

    if lat.nil? || lng.nil?
      return respond_invalid_refresh
    end

    radius_km = parse_radius_km(params[:radius_km])
    mrds_records = Clients::UsgsMrdsClient.search_nearby(
      lat: lat,
      lng: lng,
      radius_km: radius_km,
      force_refresh: true
    )
    mindat_records = if Clients::MindatClient.configured?
      Clients::MindatClient.search_nearby(
        lat: lat,
        lng: lng,
        radius_km: radius_km,
        force_refresh: true
      )
    else
      []
    end

    display_radius_km = [ radius_km, CARD_MIN_DISPLAY_RADIUS_KM ].max
    occurrences = fetch_nearby(lat: lat, lng: lng, radius_km: display_radius_km, limit: CARD_LIMIT)
    refresh_status = build_refresh_status(mrds_records.size, mindat_records.size)

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "mineral_occurrences_card",
          partial: "samples/mineral_occurrences_card",
          locals: {
            mineral_occurrences: occurrences,
            lat: lat,
            lng: lng,
            refresh_status: refresh_status
          }
        )
      end
      format.json do
        render json: {
          status: "ok",
          message: refresh_status,
          refreshed_counts: {
            usgs_mrds: mrds_records.size,
            mindat: mindat_records.size
          },
          mineral_occurrences: serialize_occurrences(occurrences, lat, lng)
        }
      end
      format.html { redirect_back fallback_location: root_path, notice: refresh_status }
    end
  end

  private

  def fetch_nearby(lat:, lng:, radius_km:, limit:, source: nil)
    scope = MineralOccurrence
      .where.not(location: nil)
      .within_radius(lat, lng, radius_km * 1000.0)
      .with_distance_from(lat, lng)
      .ordered_by_distance(lat, lng)
    scope = scope.by_source(source.to_s.strip) if source.present?
    scope.limit(limit).to_a
  end

  def serialize_occurrences(occurrences, lat, lng)
    occurrences.map do |occ|
      {
        id: occ.id,
        external_id: occ.external_id,
        name: occ.name,
        source: occ.source,
        deposit_type: occ.deposit_type,
        commodities: Array(occ.commodities),
        minerals: Array(occ.minerals),
        ceramic_highlights: occ.ceramic_highlights,
        lat: occ.latitude&.round(5),
        lng: occ.longitude&.round(5),
        distance_km: distance_km_for(occ, lat, lng)
      }
    end
  end

  def distance_km_for(occ, lat, lng)
    if occ.respond_to?(:distance_meters) && occ.distance_meters.present?
      (occ.distance_meters.to_f / 1000.0).round(2)
    elsif occ.latitude.present? && occ.longitude.present?
      haversine_km(lat, lng, occ.latitude, occ.longitude).round(2)
    end
  end

  def haversine_km(lat1, lng1, lat2, lng2)
    rad = Math::PI / 180.0
    dlat = (lat2 - lat1) * rad
    dlng = (lng2 - lng1) * rad
    a = (Math.sin(dlat / 2.0)**2) +
      Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * (Math.sin(dlng / 2.0)**2)
    6371.0 * 2.0 * Math.atan2(Math.sqrt(a), Math.sqrt(1.0 - a))
  end

  def build_refresh_status(mrds_count, mindat_count)
    if Clients::MindatClient.configured?
      "Live refresh complete: #{mrds_count} USGS MRDS and #{mindat_count} Mindat.org occurrence(s) synced."
    else
      "Live refresh complete: #{mrds_count} USGS MRDS occurrence(s) synced (set MINDAT_API_TOKEN to also query Mindat.org)."
    end
  end

  def respond_invalid_refresh
    error_message = "Valid lat and lng parameters are required to refresh mineral occurrences."
    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "mineral_occurrences_card",
          partial: "samples/mineral_occurrences_card",
          locals: {
            mineral_occurrences: [],
            lat: nil,
            lng: nil,
            refresh_error: error_message
          }
        ), status: :unprocessable_entity
      end
      format.json { render json: { error: error_message }, status: :unprocessable_entity }
      format.html { redirect_back fallback_location: root_path, alert: error_message }
    end
  end

  def parse_coordinate(value, min, max)
    return nil if value.blank?

    num = Float(value)
    return nil if num.nan? || num.infinite? || !num.between?(min, max)

    num
  rescue ArgumentError, TypeError
    nil
  end

  def parse_radius_km(value)
    return DEFAULT_RADIUS_KM if value.blank?

    num = Float(value)
    return DEFAULT_RADIUS_KM if num.nan? || num.infinite?

    num.clamp(MIN_RADIUS_KM, MAX_RADIUS_KM)
  rescue ArgumentError, TypeError
    DEFAULT_RADIUS_KM
  end

  def parse_limit(value)
    return DEFAULT_LIMIT if value.blank?

    Integer(value.to_s, 10).clamp(1, MAX_LIMIT)
  rescue ArgumentError, TypeError
    DEFAULT_LIMIT
  end
end
