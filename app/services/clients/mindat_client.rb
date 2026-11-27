# frozen_string_literal: true

require "faraday"
require "json"

module Clients
  class MindatClient
    class Error < StandardError; end

    class HttpError < Error
      attr_reader :status

      def initialize(message, status:)
        @status = status
        super(message)
      end
    end

    class NetworkError < Error; end

    BASE_URL = "https://api.mindat.org"
    ENDPOINT_PATH = "/localities/"
    SOURCE_NAME = "mindat"
    DEFAULT_RADIUS_KM = 50.0
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_TIMEOUT = 12
    DEFAULT_MAX_RETRIES = 2
    DEFAULT_MAX_PAGES = 3
    KM_PER_DEGREE_LAT = 111.32
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

    ELEMENT_TO_COMMODITY = {
      "li" => "Lithium",
      "b" => "Boron",
      "f" => "Fluorine",
      "mg" => "Magnesium",
      "al" => "Aluminum",
      "si" => "Silica",
      "s" => "Sulfur",
      "k" => "Potassium",
      "ca" => "Calcium",
      "ti" => "Titanium",
      "v" => "Vanadium",
      "cr" => "Chromium",
      "mn" => "Manganese",
      "fe" => "Iron",
      "co" => "Cobalt",
      "ni" => "Nickel",
      "cu" => "Copper",
      "zn" => "Zinc",
      "sr" => "Strontium",
      "zr" => "Zirconium",
      "sn" => "Tin",
      "ba" => "Barium"
    }.freeze

    def self.configured?(api_token = ENV["MINDAT_API_TOKEN"])
      !api_token.to_s.strip.empty?
    end

    def self.search_nearby(lat:, lng:, radius_km: DEFAULT_RADIUS_KM, api_token: ENV["MINDAT_API_TOKEN"], force_refresh: false, **options)
      new(api_token: api_token, **options).search_nearby(
        lat: lat,
        lng: lng,
        radius_km: radius_km,
        force_refresh: force_refresh
      )
    end

    def self.search_nearby!(lat:, lng:, radius_km: DEFAULT_RADIUS_KM, api_token: ENV["MINDAT_API_TOKEN"], force_refresh: false, **options)
      new(api_token: api_token, **options).search_nearby!(
        lat: lat,
        lng: lng,
        radius_km: radius_km,
        force_refresh: force_refresh
      )
    end

    def initialize(
      api_token: ENV["MINDAT_API_TOKEN"],
      connection: nil,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      timeout: DEFAULT_TIMEOUT,
      max_retries: DEFAULT_MAX_RETRIES,
      max_pages: DEFAULT_MAX_PAGES,
      retry_delay: default_retry_delay,
      logger: Rails.logger
    )
      @api_token = api_token.to_s.strip
      @connection = connection
      @open_timeout = open_timeout
      @timeout = timeout
      @max_retries = max_retries
      @max_pages = [ max_pages.to_i, 1 ].max
      @retry_delay = retry_delay.to_f
      @logger = logger
    end

    def configured?
      !@api_token.empty?
    end

    def search_nearby(lat:, lng:, radius_km: DEFAULT_RADIUS_KM, force_refresh: false)
      search_nearby!(lat: lat, lng: lng, radius_km: radius_km, force_refresh: force_refresh)
    rescue Error => e
      @logger&.warn("[Clients::MindatClient] search_nearby failed for (#{lat}, #{lng}): #{e.message}")
      []
    end

    def search_nearby!(lat:, lng:, radius_km: DEFAULT_RADIUS_KM, force_refresh: false)
      return [] unless configured?

      lat_f, lng_f = validate_coordinates!(lat, lng)
      radius_km_f = validate_radius!(radius_km)

      unless force_refresh
        cached = find_cached_occurrences(lat_f, lng_f, radius_km_f)
        return cached if cached.any?
      end

      bbox = compute_bounding_box(lat_f, lng_f, radius_km_f)
      raw_results = fetch_paginated_results(bbox)
      return [] if raw_results.empty?

      seen_ids = {}
      persisted = []

      raw_results.each do |entry|
        parsed = parse_locality(entry)
        next if parsed.nil?
        next if seen_ids[parsed[:external_id]]

        seen_ids[parsed[:external_id]] = true
        persisted << upsert_occurrence(parsed)
      end

      persisted
    end

    private

    class RetryableStatusError < StandardError; end

    def default_retry_delay
      Rails.env.test? ? 0.0 : 0.5
    end

    def validate_coordinates!(lat, lng)
      lat_f = parse_float(lat)
      lng_f = parse_float(lng)

      if lat_f.nil? || lng_f.nil? || !lat_f.between?(-90.0, 90.0) || !lng_f.between?(-180.0, 180.0)
        raise Error, "Invalid coordinates: lat=#{lat.inspect}, lng=#{lng.inspect}"
      end

      [ lat_f, lng_f ]
    end

    def validate_radius!(radius_km)
      val = parse_float(radius_km)
      if val.nil? || val <= 0.0
        raise Error, "Invalid radius_km: #{radius_km.inspect}"
      end

      val.clamp(0.5, 500.0)
    end

    def parse_float(value)
      return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)

      num = Float(value)
      return nil if num.nan? || num.infinite?

      num
    rescue ArgumentError, TypeError
      nil
    end

    def find_cached_occurrences(lat, lng, radius_km)
      MineralOccurrence
        .by_source(SOURCE_NAME)
        .within_radius(lat, lng, radius_km * 1000.0)
        .ordered_by_distance(lat, lng)
        .to_a
    end

    def compute_bounding_box(lat, lng, radius_km)
      lat_delta = radius_km / KM_PER_DEGREE_LAT
      cos_lat = [ Math.cos(lat * Math::PI / 180.0).abs, 0.01 ].max
      lng_delta = radius_km / (KM_PER_DEGREE_LAT * cos_lat)

      {
        lat_min: [ lat - lat_delta, -90.0 ].max.round(5),
        lat_max: [ lat + lat_delta, 90.0 ].min.round(5),
        lon_min: [ lng - lng_delta, -180.0 ].max.round(5),
        lon_max: [ lng + lng_delta, 180.0 ].min.round(5)
      }
    end

    def connection
      @connection ||= Faraday.new(url: BASE_URL) do |f|
        f.options.open_timeout = @open_timeout
        f.options.timeout = @timeout
        f.headers["Accept"] = "application/json"
        f.headers["Authorization"] = "Token #{@api_token}"
        f.headers["User-Agent"] = "CeramicMaterialAssayPlatform/1.0"
        f.adapter Faraday.default_adapter
      end
    end

    def fetch_paginated_results(bbox)
      results = []
      next_target = ENDPOINT_PATH
      params = bbox
      page = 0

      while next_target.present? && page < @max_pages
        page += 1
        payload = fetch_json(next_target, params)
        break unless payload.is_a?(Hash)

        page_results = payload["results"]
        results.concat(page_results) if page_results.is_a?(Array)

        next_target = extract_safe_next_path(payload["next"])
        params = nil
      end

      results
    end

    def extract_safe_next_path(next_url)
      return nil if next_url.nil? || next_url.to_s.strip.empty?

      uri = URI.parse(next_url.to_s.strip)
      return nil if uri.host.present? && uri.host.downcase != "api.mindat.org"
      return nil if uri.scheme.present? && uri.scheme.downcase != "https"

      path = uri.path.to_s
      return nil if path.empty?

      uri.query.present? ? "#{path}?#{uri.query}" : path
    rescue URI::InvalidURIError
      nil
    end

    def fetch_json(path, params)
      attempts = 0

      begin
        attempts += 1
        response = params ? connection.get(path, params) : connection.get(path)

        if response.status >= 200 && response.status < 300
          return parse_json!(response.body)
        end

        if retryable_status?(response.status) && attempts <= @max_retries
          sleep_backoff(attempts)
          raise RetryableStatusError, "HTTP #{response.status}"
        end

        raise HttpError.new(
          "Mindat API returned HTTP #{response.status}",
          status: response.status
        )
      rescue RetryableStatusError
        retry
      rescue *RETRYABLE_EXCEPTIONS => e
        if attempts <= @max_retries
          sleep_backoff(attempts)
          retry
        end

        raise NetworkError, "Mindat API network error after #{attempts} attempt(s): #{e.class}: #{e.message}"
      rescue Faraday::Error => e
        raise NetworkError, "Mindat API request failed: #{e.class}: #{e.message}"
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
      raise Error, "Invalid JSON from Mindat API: #{e.message}"
    end

    def parse_locality(entry)
      return nil unless entry.is_a?(Hash)

      ext_id = present_string(entry["id"])
      name = present_string(entry["txt"]) || present_string(entry["name"]) || present_string(entry["longid"])
      lat = parse_float(entry["latitude"] || entry["lat"])
      lng = parse_float(entry["longitude"] || entry["lon"] || entry["lng"])

      return nil if ext_id.nil? || name.nil?
      return nil if lat.nil? || lng.nil? || !lat.between?(-90.0, 90.0) || !lng.between?(-180.0, 180.0)

      minerals = extract_minerals(entry)
      commodities = extract_commodities(entry)
      deposit_type = extract_deposit_type(entry)

      {
        external_id: ext_id,
        name: name,
        latitude: lat,
        longitude: lng,
        commodities: commodities,
        minerals: minerals,
        deposit_type: deposit_type,
        raw_metadata: build_raw_metadata(entry, ext_id)
      }
    end

    def extract_minerals(entry)
      raw_list =
        entry["minerals"] ||
        entry["locality_minerals"] ||
        entry["associated_minerals"] ||
        entry["geomaterials"]

      terms = case raw_list
      when Array
        raw_list.flat_map do |item|
          if item.is_a?(Hash)
            present_string(item["name"] || item["mineral_name"] || item["txt"] || item["label"])
          else
            split_terms(item)
          end
        end
      when String
        split_terms(raw_list)
      else
        []
      end

      terms.compact.uniq
    end

    def extract_commodities(entry)
      explicit = split_terms(entry["commodities"] || entry["commodity"])
      from_elements = parse_elements(entry["elements"]).filter_map do |sym|
        ELEMENT_TO_COMMODITY[sym.downcase] || (sym.length > 2 ? sym : nil)
      end

      (explicit + from_elements).map(&:strip).reject(&:empty?).uniq
    end

    def parse_elements(raw)
      case raw
      when Array
        raw.flat_map { |item| parse_elements(item) }
      when String
        raw.split(/[-,;|\s]+/).map(&:strip).reject(&:empty?)
      else
        []
      end
    end

    def extract_deposit_type(entry)
      raw = entry["loc_type"] || entry["locality_type"] || entry["deposit_type"]
      case raw
      when Array
        raw.map { |v| present_string(v) }.compact.uniq.join(", ").presence
      when Hash
        present_string(raw["name"] || raw["label"] || raw["txt"])
      else
        present_string(raw)
      end
    end

    def build_raw_metadata(entry, ext_id)
      meta = {
        "mindat_id" => ext_id,
        "elements" => entry["elements"],
        "country" => present_string(entry["country"]),
        "region" => present_string(entry["region"]),
        "description" => present_string(entry["description_short"] || entry["description"])
      }.compact

      if ext_id.match?(/\A\d+\z/)
        meta["mindat_url"] = "https://www.mindat.org/loc-#{ext_id}.html"
      end

      meta
    end

    def split_terms(value)
      case value
      when Array
        value.flat_map { |v| split_terms(v) }
      when String
        value.split(/[,;|]+/).map(&:strip).reject(&:empty?)
      else
        []
      end
    end

    def present_string(value)
      return nil if value.nil?

      str = value.to_s.strip
      str.empty? ? nil : str
    end

    def upsert_occurrence(data)
      record = MineralOccurrence.find_or_initialize_by(
        source: SOURCE_NAME,
        external_id: data[:external_id]
      )
      apply_attributes(record, data)
      record.save!
      record
    rescue ActiveRecord::RecordNotUnique
      record = MineralOccurrence.find_by!(
        source: SOURCE_NAME,
        external_id: data[:external_id]
      )
      apply_attributes(record, data)
      record.save!
      record
    end

    def apply_attributes(record, data)
      record.name = data[:name]
      record.commodities = data[:commodities]
      record.minerals = data[:minerals]
      record.deposit_type = data[:deposit_type] if data[:deposit_type].present? || record.new_record?
      record.location = Geolocatable.factory.point(data[:longitude], data[:latitude])
      record.raw_metadata = data[:raw_metadata]
    end
  end
end
