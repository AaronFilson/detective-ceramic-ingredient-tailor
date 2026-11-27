# frozen_string_literal: true

require "faraday"
require "json"

module Clients
  class UsdaSsurgoClient
    class Error < StandardError; end

    class HttpError < Error
      attr_reader :status

      def initialize(message, status:)
        @status = status
        super(message)
      end
    end

    class NetworkError < Error; end

    BASE_URL = "https://SDMDataAccess.sc.egov.usda.gov"
    ENDPOINT_PATH = "/Tabular/post.rest"
    CACHE_RADIUS_METERS = 250
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
      @logger&.warn("[Clients::UsdaSsurgoClient] lookup failed for (#{lat}, #{lng}): #{e.message}")
      nil
    end

    def lookup!(lat:, lng:, force_refresh: false)
      lat_f, lng_f = validate_coordinates!(lat, lng)

      unless force_refresh
        cached = find_cached_profile(lat_f, lng_f)
        return cached if cached
      end

      sql = build_sda_query(lat_f, lng_f)
      payload = fetch_payload(sql)
      parsed = parse_sda_table(payload)
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
        .within_radius(lat, lng, CACHE_RADIUS_METERS)
        .ordered_by_distance(lat, lng)
        .first
    end

    def build_sda_query(lat_f, lng_f)
      wkt_point = format("point(%.6f %.6f)", lng_f, lat_f)
      <<~SQL.squish
        SELECT mu.mukey, mu.muname, c.compname, c.comppct_r,
               ch.hzname, ch.hzdept_r, ch.hzdepb_r, ch.claytotal_r, ch.plasticindex_r, ch.caco3_r
        FROM mapunit AS mu
        INNER JOIN SDA_Get_Mukey_from_intersection_with_WktWgs84('#{wkt_point}') AS sda
          ON mu.mukey = sda.mukey
        INNER JOIN component AS c
          ON c.mukey = mu.mukey
        LEFT JOIN chorizon AS ch
          ON ch.cokey = c.cokey
        ORDER BY c.comppct_r DESC, ch.hzdept_r ASC
      SQL
    end

    def connection
      @connection ||= Faraday.new(url: BASE_URL) do |f|
        f.options.open_timeout = @open_timeout
        f.options.timeout = @timeout
        f.headers["Accept"] = "application/json"
        f.headers["Content-Type"] = "application/json"
        f.headers["User-Agent"] = "CeramicMaterialAssayPlatform/1.0"
        f.adapter Faraday.default_adapter
      end
    end

    def fetch_payload(sql)
      attempts = 0
      body = JSON.generate({ query: sql, format: "JSON" })

      begin
        attempts += 1
        response = connection.post(ENDPOINT_PATH, body)

        if response.status >= 200 && response.status < 300
          return parse_json!(response.body)
        end

        if retryable_status?(response.status) && attempts <= @max_retries
          sleep_backoff(attempts)
          raise RetryableStatusError, "HTTP #{response.status}"
        end

        raise HttpError.new(
          "USDA SSURGO SDA API returned HTTP #{response.status}",
          status: response.status
        )
      rescue RetryableStatusError
        retry
      rescue *RETRYABLE_EXCEPTIONS => e
        if attempts <= @max_retries
          sleep_backoff(attempts)
          retry
        end

        raise NetworkError, "USDA SSURGO SDA API network error after #{attempts} attempt(s): #{e.class}: #{e.message}"
      rescue Faraday::Error => e
        raise NetworkError, "USDA SSURGO SDA API request failed: #{e.class}: #{e.message}"
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
      raise Error, "Invalid JSON from USDA SSURGO SDA API: #{e.message}"
    end

    def parse_sda_table(payload)
      return nil unless payload.is_a?(Hash)

      rows = payload["Table"]
      return nil unless rows.is_a?(Array) && rows.any?

      normalized_rows = rows.filter_map { |row| normalize_sda_row(row) }
      return nil if normalized_rows.empty?

      grouped = normalized_rows.group_by { |r| [ r[:mukey], r[:component_name], r[:component_percent] ] }
      dominant_rows = grouped.values.max_by do |comp_rows|
        pct = comp_rows.first[:component_percent] || -1.0
        clay_count = comp_rows.count { |r| !r[:clay_pct].nil? }
        [ pct, clay_count ]
      end

      return nil if dominant_rows.nil? || dominant_rows.empty?

      first = dominant_rows.first
      horizons = build_horizons(dominant_rows)

      {
        mukey: first[:mukey],
        map_unit_name: first[:map_unit_name],
        component_name: first[:component_name],
        component_percent: first[:component_percent],
        horizons: horizons,
        max_clay_pct: horizons.filter_map { |h| h["clay_pct"] }.max,
        max_plasticity_index: horizons.filter_map { |h| h["plasticity_index"] }.max,
        max_caco3_pct: horizons.filter_map { |h| h["caco3_pct"] }.max
      }
    end

    def normalize_sda_row(row)
      return nil unless row.is_a?(Array) && row.length >= 4

      mukey = present_string(row[0])
      return nil if mukey.nil? || mukey.casecmp("mukey").zero?

      {
        mukey: mukey,
        map_unit_name: present_string(row[1]),
        component_name: present_string(row[2]),
        component_percent: parse_decimal(row[3]),
        hzname: present_string(row[4]),
        top_cm: parse_depth(row[5]),
        bottom_cm: parse_depth(row[6]),
        clay_pct: parse_decimal(row[7]),
        plasticity_index: parse_decimal(row[8]),
        caco3_pct: parse_decimal(row[9])
      }
    end

    def build_horizons(component_rows)
      seen = {}

      component_rows
        .reject { |r| horizon_blank?(r) }
        .sort_by { |r| [ r[:top_cm].nil? ? Float::INFINITY : r[:top_cm].to_f, r[:bottom_cm].nil? ? Float::INFINITY : r[:bottom_cm].to_f ] }
        .each_with_object([]) do |r, acc|
          dedup_key = [ r[:hzname], r[:top_cm], r[:bottom_cm] ]
          next if seen[dedup_key]

          seen[dedup_key] = true
          acc << {
            "hzname" => r[:hzname],
            "top_cm" => r[:top_cm],
            "bottom_cm" => r[:bottom_cm],
            "clay_pct" => r[:clay_pct],
            "plasticity_index" => r[:plasticity_index],
            "caco3_pct" => r[:caco3_pct]
          }
        end
    end

    def horizon_blank?(row)
      row[:hzname].nil? &&
        row[:top_cm].nil? &&
        row[:bottom_cm].nil? &&
        row[:clay_pct].nil? &&
        row[:plasticity_index].nil? &&
        row[:caco3_pct].nil?
    end

    def present_string(value)
      return nil if value.nil?

      str = value.to_s.strip
      str.empty? ? nil : str
    end

    def parse_decimal(value)
      return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)

      num = Float(value)
      return nil if num.nan? || num.infinite? || num.negative?

      num.round(2)
    rescue ArgumentError, TypeError
      nil
    end

    def parse_depth(value)
      num = parse_decimal(value)
      return nil if num.nil?

      (num % 1.0).zero? ? num.to_i : num
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
      profile.map_unit_name = data[:map_unit_name]
      profile.component_name = data[:component_name]
      profile.component_percent = data[:component_percent]
      profile.horizons = data[:horizons]
      profile.max_clay_pct = data[:max_clay_pct]
      profile.max_plasticity_index = data[:max_plasticity_index]
      profile.max_caco3_pct = data[:max_caco3_pct]
      profile.location = Geolocatable.factory.point(lng, lat)
      profile.fetched_at = Time.current
    end
  end
end
