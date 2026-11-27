# frozen_string_literal: true

require "faraday"
require "json"
require "rgeo/geo_json"

module Clients
  class MacrostratClient
    class Error < StandardError; end

    class HttpError < Error
      attr_reader :status

      def initialize(message, status:)
        @status = status
        super(message)
      end
    end

    class NetworkError < Error; end

    BASE_URL = "https://macrostrat.org"
    ENDPOINT_PATH = "/api/v2/geologic_units/map"
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_TIMEOUT = 10
    DEFAULT_MAX_RETRIES = 2
    RETRYABLE_STATUSES = [429, *(500..599)].freeze
    RETRYABLE_EXCEPTIONS = [
      Faraday::TimeoutError,
      Faraday::ConnectionFailed,
      Faraday::SSLError,
      Timeout::Error,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      SocketError
    ].freeze

    def self.lookup(lat:, lng:, force_refresh: false, **options)
      new(**options).lookup(lat: lat, lng: lng, force_refresh: force_refresh)
    end

    def self.lookup!(lat:, lng:, force_refresh: false, **options)
      new(**options).lookup!(lat: lat, lng: lng, force_refresh: force_refresh)
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
      @logger&.warn("[Clients::MacrostratClient] lookup failed for (#{lat}, #{lng}): #{e.message}")
      nil
    end

    def lookup!(lat:, lng:, force_refresh: false)
      lat_f, lng_f = validate_coordinates!(lat, lng)

      unless force_refresh
        cached = find_cached_unit(lat_f, lng_f)
        return cached if cached
      end

      payload = fetch_payload(lat_f, lng_f)
      extracted = extract_unit_data(payload, lat_f, lng_f)
      return nil unless extracted

      upsert_geologic_unit(extracted)
    end

    private

    def default_retry_delay
      Rails.env.test? ? 0.0 : 0.5
    end

    def geo_factory
      @geo_factory ||= RGeo::Cartesian.preferred_factory(srid: 4326)
    end

    def validate_coordinates!(lat, lng)
      lat_f = parse_coordinate(lat)
      lng_f = parse_coordinate(lng)

      if lat_f.nil? || lng_f.nil? || !lat_f.between?(-90.0, 90.0) || !lng_f.between?(-180.0, 180.0)
        raise Error, "Invalid coordinates: lat=#{lat.inspect}, lng=#{lng.inspect}"
      end

      [lat_f, lng_f]
    end

    def parse_coordinate(value)
      return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)

      num = Float(value)
      return nil if num.nan? || num.infinite?

      num
    rescue ArgumentError, TypeError
      nil
    end

    def find_cached_unit(lat, lng)
      GeologicUnit
        .where(
          "boundary IS NOT NULL AND ST_Covers(boundary, ST_SetSRID(ST_MakePoint(?, ?), 4326))",
          lng,
          lat
        )
        .order(Arel.sql("ST_Area(boundary) ASC"), updated_at: :desc)
        .first
    end

    def connection
      @connection ||= Faraday.new(url: BASE_URL) do |f|
        f.options.open_timeout = @open_timeout
        f.options.timeout = @timeout
        f.headers["Accept"] = "application/json"
        f.headers["User-Agent"] = "CeramicMaterialAssayPlatform/1.0"
        f.adapter Faraday.default_adapter
      end
    end

    def fetch_payload(lat, lng)
      attempts = 0

      begin
        attempts += 1
        response = connection.get(ENDPOINT_PATH, { lat: lat, lng: lng, format: "geojson" })

        if response.status >= 200 && response.status < 300
          return parse_json!(response.body)
        end

        if retryable_status?(response.status) && attempts <= @max_retries
          sleep_backoff(attempts)
          raise RetryableStatusError, "HTTP #{response.status}"
        end

        raise HttpError.new(
          "Macrostrat API returned HTTP #{response.status}",
          status: response.status
        )
      rescue RetryableStatusError
        retry
      rescue *RETRYABLE_EXCEPTIONS => e
        if attempts <= @max_retries
          sleep_backoff(attempts)
          retry
        end

        raise NetworkError, "Macrostrat API network error after #{attempts} attempt(s): #{e.class}: #{e.message}"
      rescue Faraday::Error => e
        raise NetworkError, "Macrostrat API request failed: #{e.class}: #{e.message}"
      end
    end

    class RetryableStatusError < StandardError; end

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
      raise Error, "Invalid JSON from Macrostrat API: #{e.message}"
    end

    def extract_unit_data(payload, lat, lng)
      candidates = extract_candidates(payload)
      return nil if candidates.empty?

      parsed = candidates.filter_map { |candidate| normalize_candidate(candidate) }
      return nil if parsed.empty?

      point = geo_factory.point(lng, lat)
      covering = parsed.find { |item| item[:boundary] && geometry_covers_point?(item[:boundary], point) }
      return covering if covering

      parsed.find { |item| item[:boundary].present? } || parsed.first
    end

    def extract_candidates(payload)
      case payload
      when Hash
        if geojson_feature_collection?(payload)
          Array(payload["features"]).select { |f| f.is_a?(Hash) }
        elsif payload["type"] == "Feature"
          [payload]
        elsif payload.dig("success", "data").is_a?(Hash) && geojson_feature_collection?(payload.dig("success", "data"))
          Array(payload.dig("success", "data", "features")).select { |f| f.is_a?(Hash) }
        elsif payload.dig("success", "data").is_a?(Array)
          payload.dig("success", "data").select { |u| u.is_a?(Hash) }
        elsif payload["data"].is_a?(Array)
          payload["data"].select { |u| u.is_a?(Hash) }
        else
          []
        end
      when Array
        payload.select { |u| u.is_a?(Hash) }
      else
        []
      end
    end

    def geojson_feature_collection?(hash)
      hash["type"] == "FeatureCollection" && hash["features"].is_a?(Array)
    end

    def normalize_candidate(candidate)
      if candidate["type"] == "Feature" || candidate["properties"].is_a?(Hash)
        props = candidate["properties"].is_a?(Hash) ? candidate["properties"] : {}
        raw_geom = candidate["geometry"]
      else
        props = candidate
        raw_geom = candidate["geometry"] || candidate["geom"]
      end

      map_id = parse_integer(props["map_id"] || props["unit_id"])
      return nil unless map_id

      {
        macrostrat_id: map_id,
        name: present_string(props["name"]),
        strat_name: present_string(props["strat_name"]),
        age: extract_age(props),
        lithology: build_lithology(props),
        boundary: decode_geometry(raw_geom)
      }
    end

    def parse_integer(value)
      return value if value.is_a?(Integer)
      return nil if value.nil?

      str = value.to_s.strip
      return nil if str.empty?

      Integer(str, 10)
    rescue ArgumentError, TypeError
      nil
    end

    def present_string(value)
      str = value.to_s.strip
      return nil if str.empty? || str.casecmp("none").zero?

      str
    end

    def extract_age(props)
      direct = present_string(props["age"])
      return direct if direct

      interval = [present_string(props["b_int_name"]), present_string(props["t_int_name"])].compact.uniq
      interval.empty? ? nil : interval.join(" - ")
    end

    def build_lithology(props)
      raw_lith = present_string(props["lith"])
      liths = props["liths"]
      liths = nil if liths.respond_to?(:empty?) && liths.empty?
      descrip = present_string(props["descrip"])
      color = present_string(props["color"])

      {
        "raw" => raw_lith,
        "liths" => liths,
        "descrip" => descrip,
        "color" => color
      }.compact
    end

    def decode_geometry(raw_geom)
      return nil if raw_geom.nil?

      geom_obj =
        if raw_geom.is_a?(String)
          trimmed = raw_geom.strip
          return nil if trimmed.empty?

          if trimmed.start_with?("{")
            JSON.parse(trimmed)
          else
            return RGeo::WKRep::WKTParser.new(geo_factory, support_ewkt: true).parse(trimmed)
          end
        else
          raw_geom
        end

      decoded = RGeo::GeoJSON.decode(geom_obj, geo_factory: geo_factory)
      return nil if decoded.nil? || (decoded.respond_to?(:empty?) && decoded.empty?)

      decoded
    rescue JSON::ParserError, RGeo::Error::RGeoError, TypeError, ArgumentError => e
      @logger&.warn("[Clients::MacrostratClient] geometry decode failed: #{e.class}: #{e.message}")
      nil
    end

    def geometry_covers_point?(boundary, point)
      boundary.contains?(point) || boundary.intersects?(point)
    rescue RGeo::Error::RGeoError
      false
    end

    def upsert_geologic_unit(data)
      unit = GeologicUnit.find_or_initialize_by(macrostrat_id: data[:macrostrat_id])
      apply_unit_attributes(unit, data)
      unit.save!
      unit
    rescue ActiveRecord::RecordNotUnique
      unit = GeologicUnit.find_by!(macrostrat_id: data[:macrostrat_id])
      apply_unit_attributes(unit, data)
      unit.save!
      unit
    end

    def apply_unit_attributes(unit, data)
      unit.name = data[:name] if data[:name].present? || unit.new_record?
      unit.strat_name = data[:strat_name] if data[:strat_name].present? || unit.new_record?
      unit.age = data[:age] if data[:age].present? || unit.new_record?
      unit.lithology = data[:lithology] if data[:lithology].present? || unit.new_record?
      unit.boundary = data[:boundary] if data[:boundary].present?
    end
  end
end
