# frozen_string_literal: true

require "faraday"
require "json"

module Clients
  class IsricSoilgridsClient
    class Error < StandardError; end

    class HttpError < Error
      attr_reader :status

      def initialize(message, status:)
        @status = status
        super(message)
      end
    end

    class NetworkError < Error; end

    BASE_URL = "https://rest.isric.org"
    ENDPOINT_PATH = "/soilgrids/v2.0/properties/query"
    SOURCE = "isric_soilgrids"
    MAP_UNIT_LABEL = "ISRIC SoilGrids v2 (250m Global)"
    CACHE_RADIUS_METERS = 500
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_TIMEOUT = 12
    DEFAULT_MAX_RETRIES = 2
    RETRYABLE_STATUSES = [ 429, *(500..599) ].freeze
    RETRYABLE_EXCEPTIONS = [
      Faraday::TimeoutError,
      Faraday::ConnectionFailed,
      Faraday::SSLError,
      Timeout::Error,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      SocketError
    ].freeze

    PROPERTIES = %w[clay silt sand cec phh2o soc].freeze

    DEPTH_SPECS = [
      { label: "0-5cm", hzname: "D1", top_cm: 0, bottom_cm: 5 },
      { label: "5-15cm", hzname: "D2", top_cm: 5, bottom_cm: 15 },
      { label: "15-30cm", hzname: "D3", top_cm: 15, bottom_cm: 30 },
      { label: "30-60cm", hzname: "D4", top_cm: 30, bottom_cm: 60 },
      { label: "60-100cm", hzname: "D5", top_cm: 60, bottom_cm: 100 },
      { label: "100-200cm", hzname: "D6", top_cm: 100, bottom_cm: 200 }
    ].freeze

    DEPTHS = DEPTH_SPECS.map { |spec| spec[:label] }.freeze

    # ISRIC SoilGrids v2 mapped integer-unit conversion divisors:
    # - clay, silt, sand: g/kg / 10.0 => wt% (g/100g)
    # - phh2o: pH * 10 / 10.0 => pH
    # - cec: mmol(c)/kg / 10.0 => cmol(c)/kg (meq/100g)
    # - soc: dg/kg / 10.0 => g/kg
    PROPERTY_SPECS = {
      "clay" => { field: "clay_pct", divisor: 10.0 },
      "silt" => { field: "silt_pct", divisor: 10.0 },
      "sand" => { field: "sand_pct", divisor: 10.0 },
      "phh2o" => { field: "ph", divisor: 10.0 },
      "cec" => { field: "cec_cmol_kg", divisor: 10.0 },
      "soc" => { field: "soc_g_kg", divisor: 10.0 }
    }.freeze

    def self.lookup(lat:, lng:, force_refresh: false, **options)
      new(**options).lookup(lat: lat, lng: lng, force_refresh: force_refresh)
    end

    def self.lookup!(lat:, lng:, force_refresh: false, **options)
      new(**options).lookup!(lat: lat, lng: lng, force_refresh: force_refresh)
    end

    # USDA NRCS 12-class Soil Texture Triangle classification from clay/silt/sand wt%.
    def self.classify_texture(clay, silt, sand)
      return "Soil Profile" if clay.nil? || silt.nil? || sand.nil?

      c = clay.to_f
      si = silt.to_f
      sa = sand.to_f
      total = c + si + sa
      return "Soil Profile" unless total.positive?

      scale = 100.0 / total
      c *= scale
      si *= scale
      sa *= scale

      if c >= 40.0
        return "Silty Clay" if si >= 40.0
        return "Sandy Clay" if sa >= 45.0

        "Clay"
      elsif c >= 27.0
        return "Silty Clay Loam" if sa <= 20.0
        return "Sandy Clay Loam" if sa > 45.0

        "Clay Loam"
      elsif c >= 20.0 && si < 28.0 && sa > 45.0
        "Sandy Clay Loam"
      elsif si >= 80.0 && c < 12.0
        "Silt"
      elsif (si >= 50.0 && c >= 12.0 && c < 27.0) || (si >= 50.0 && si < 80.0 && c < 12.0)
        "Silt Loam"
      elsif c >= 7.0 && c < 27.0 && si >= 28.0 && si < 50.0 && sa <= 52.0
        "Loam"
      elsif si + (1.5 * c) < 15.0
        "Sand"
      elsif si + (2.0 * c) < 30.0
        "Loamy Sand"
      else
        "Sandy Loam"
      end
    end

    def initialize(
      connection: nil,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      timeout: DEFAULT_TIMEOUT,
      max_retries: DEFAULT_MAX_RETRIES,
      retry_delay: default_retry_delay,
      logger: Rails.logger
    )
      @connection = connection
      @open_timeout = open_timeout
      @timeout = timeout
      @max_retries = max_retries
      @retry_delay = retry_delay.to_f
      @logger = logger
    end

    def lookup(lat:, lng:, force_refresh: false)
      lookup!(lat: lat, lng: lng, force_refresh: force_refresh)
    rescue Error => e
      @logger&.warn("[Clients::IsricSoilgridsClient] lookup failed for (#{lat}, #{lng}): #{e.message}")
      nil
    end

    def lookup!(lat:, lng:, force_refresh: false)
      lat_f, lng_f = validate_coordinates!(lat, lng)

      unless force_refresh
        cached = find_cached_profile(lat_f, lng_f)
        return cached if cached
      end

      payload = fetch_payload(lat_f, lng_f)
      parsed = parse_soilgrids_payload(payload, lat_f, lng_f)
      return nil unless parsed

      upsert_soil_profile(parsed, lat_f, lng_f)
    end

    private

    class RetryableStatusError < StandardError; end

    def default_retry_delay
      Rails.env.test? ? 0.0 : 0.5
    end

    def validate_coordinates!(lat, lng)
      lat_f = parse_coordinate(lat)
      lng_f = parse_coordinate(lng)

      if lat_f.nil? || lng_f.nil? || !lat_f.between?(-90.0, 90.0) || !lng_f.between?(-180.0, 180.0)
        raise Error, "Invalid coordinates: lat=#{lat.inspect}, lng=#{lng.inspect}"
      end

      [ lat_f, lng_f ]
    end

    def parse_coordinate(value)
      return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)

      num = Float(value)
      return nil if num.nan? || num.infinite?

      num
    rescue ArgumentError, TypeError
      nil
    end

    def find_cached_profile(lat, lng)
      SoilProfile
        .where(source: SOURCE)
        .within_radius(lat, lng, CACHE_RADIUS_METERS)
        .ordered_by_distance(lat, lng)
        .first
    end

    def connection
      @connection ||= Faraday.new(url: BASE_URL) do |f|
        f.options.open_timeout = @open_timeout
        f.options.timeout = @timeout
        f.options.params_encoder = Faraday::FlatParamsEncoder
        f.headers["Accept"] = "application/json"
        f.headers["User-Agent"] = "CeramicMaterialAssayPlatform/1.0"
        f.adapter Faraday.default_adapter
      end
    end

    def build_query_params(lat_f, lng_f)
      {
        lon: format("%.6f", lng_f),
        lat: format("%.6f", lat_f),
        property: PROPERTIES,
        depth: DEPTHS,
        value: "mean"
      }
    end

    def fetch_payload(lat_f, lng_f)
      attempts = 0
      params = build_query_params(lat_f, lng_f)

      begin
        attempts += 1
        response = connection.get(ENDPOINT_PATH, params)

        if response.status >= 200 && response.status < 300
          return parse_json!(response.body)
        end

        if retryable_status?(response.status) && attempts <= @max_retries
          sleep_backoff(attempts)
          raise RetryableStatusError, "HTTP #{response.status}"
        end

        raise HttpError.new(
          "ISRIC SoilGrids v2 API returned HTTP #{response.status}",
          status: response.status
        )
      rescue RetryableStatusError
        retry
      rescue *RETRYABLE_EXCEPTIONS => e
        if attempts <= @max_retries
          sleep_backoff(attempts)
          retry
        end

        raise NetworkError, "ISRIC SoilGrids v2 API network error after #{attempts} attempt(s): #{e.class}: #{e.message}"
      rescue Faraday::Error => e
        raise NetworkError, "ISRIC SoilGrids v2 API request failed: #{e.class}: #{e.message}"
      end
    end

    def retryable_status?(status)
      RETRYABLE_STATUSES.include?(status)
    end

    def sleep_backoff(attempt)
      return unless @retry_delay.positive?

      Kernel.sleep(@retry_delay * (2**(attempt - 1)))
    end

    def parse_json!(body)
      return {} if body.nil? || body.to_s.strip.empty?

      JSON.parse(body.to_s)
    rescue JSON::ParserError => e
      raise Error, "Invalid JSON from ISRIC SoilGrids v2 API: #{e.message}"
    end

    def parse_soilgrids_payload(payload, lat_f, lng_f)
      return nil unless payload.is_a?(Hash)

      layers = payload.dig("properties", "layers")
      return nil unless layers.is_a?(Array) && layers.any?

      depth_buckets = DEPTH_SPECS.each_with_object({}) do |spec, acc|
        acc[spec[:label]] = {
          "hzname" => spec[:hzname],
          "top_cm" => spec[:top_cm],
          "bottom_cm" => spec[:bottom_cm],
          "clay_pct" => nil,
          "silt_pct" => nil,
          "sand_pct" => nil,
          "ph" => nil,
          "cec_cmol_kg" => nil,
          "soc_g_kg" => nil
        }
      end

      layers.each do |layer|
        next unless layer.is_a?(Hash)

        prop_name = layer["name"].to_s.downcase
        prop_spec = PROPERTY_SPECS[prop_name]
        next unless prop_spec

        Array(layer["depths"]).each do |depth_entry|
          next unless depth_entry.is_a?(Hash)

          label = normalize_depth_label(depth_entry)
          bucket = depth_buckets[label]
          next unless bucket

          raw_val = extract_depth_value(depth_entry["values"])
          next if raw_val.nil?

          bucket[prop_spec[:field]] = (raw_val / prop_spec[:divisor]).round(2)
        end
      end

      horizons = DEPTH_SPECS.filter_map do |spec|
        bucket = depth_buckets[spec[:label]]
        has_measurement = PROPERTY_SPECS.values.any? { |ps| !bucket[ps[:field]].nil? }
        bucket if has_measurement
      end

      return nil if horizons.empty?

      clay_horizon = horizons.select { |h| !h["clay_pct"].nil? }.max_by { |h| h["clay_pct"].to_f } || horizons.first
      max_clay_pct = horizons.filter_map { |h| h["clay_pct"] }.max
      soil_ph = clay_horizon["ph"] || average_field(horizons, "ph")
      cec = clay_horizon["cec_cmol_kg"] || average_field(horizons, "cec_cmol_kg")
      organic_carbon = clay_horizon["soc_g_kg"] || average_field(horizons, "soc_g_kg")
      component_name = self.class.classify_texture(
        clay_horizon["clay_pct"],
        clay_horizon["silt_pct"],
        clay_horizon["sand_pct"]
      )

      {
        mukey: build_mukey(lat_f, lng_f),
        map_unit_name: MAP_UNIT_LABEL,
        component_name: component_name,
        horizons: horizons,
        max_clay_pct: max_clay_pct,
        soil_ph: soil_ph,
        cec: cec,
        organic_carbon: organic_carbon
      }
    end

    def normalize_depth_label(depth_entry)
      raw_label = depth_entry["label"].to_s.strip
      return raw_label if DEPTHS.include?(raw_label)

      range = depth_entry["range"]
      if range.is_a?(Hash) && range["top_depth"].present? && range["bottom_depth"].present?
        candidate = "#{range["top_depth"].to_i}-#{range["bottom_depth"].to_i}cm"
        return candidate if DEPTHS.include?(candidate)
      end

      raw_label
    end

    def extract_depth_value(values)
      return nil unless values.is_a?(Hash)

      candidate = values.key?("mean") && !values["mean"].nil? ? values["mean"] : (values["Q0.5"] || values["q0.5"])
      return nil if candidate.nil? || (candidate.is_a?(String) && candidate.strip.empty?)

      num = Float(candidate)
      return nil if num.nan? || num.infinite? || num.negative?

      num
    rescue ArgumentError, TypeError
      nil
    end

    def average_field(horizons, key)
      vals = horizons.filter_map { |h| h[key] }
      return nil if vals.empty?

      (vals.sum / vals.length.to_f).round(2)
    end

    def build_mukey(lat_f, lng_f)
      lat_norm = lat_f.round(3).zero? ? 0.0 : lat_f
      lng_norm = lng_f.round(3).zero? ? 0.0 : lng_f
      "soilgrids:#{format("%.3f", lat_norm)}:#{format("%.3f", lng_norm)}"
    end

    def upsert_soil_profile(data, lat, lng)
      profile = SoilProfile.find_or_initialize_by(mukey: data[:mukey])
      apply_profile_attributes(profile, data, lat, lng)
      profile.save!
      profile
    rescue ActiveRecord::RecordNotUnique
      profile = SoilProfile.find_by!(mukey: data[:mukey])
      apply_profile_attributes(profile, data, lat, lng)
      profile.save!
      profile
    end

    def apply_profile_attributes(profile, data, lat, lng)
      profile.source = SOURCE
      profile.map_unit_name = data[:map_unit_name]
      profile.component_name = data[:component_name]
      profile.component_percent = nil
      profile.horizons = data[:horizons]
      profile.max_clay_pct = data[:max_clay_pct]
      profile.soil_ph = data[:soil_ph]
      profile.cec = data[:cec]
      profile.organic_carbon = data[:organic_carbon]
      profile.location = Geolocatable.factory.point(lng, lat)
      profile.fetched_at = Time.current
    end
  end
end
