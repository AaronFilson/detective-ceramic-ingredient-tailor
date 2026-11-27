# frozen_string_literal: true

require "faraday"
require "json"

module Clients
  class GeorocClient
    class Error < StandardError; end

    class HttpError < Error
      attr_reader :status

      def initialize(message, status:)
        @status = status
        super(message)
      end
    end

    class NetworkError < Error; end

    DEFAULT_BASE_URL = "https://api-test.georoc.eu"
    PING_PATH = "/api/v1/ping"
    SAMPLES_PATH = "/api/v1/queries/samples"
    API_KEY_HEADER = "DIGIS-API-ACCESSKEY"
    DEFAULT_LIMIT = 100
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_TIMEOUT = 15
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

    def self.configured?(api_key: ENV["GEOROC_API_KEY"])
      !api_key.to_s.strip.empty?
    end

    def self.ping(**options)
      new(**options).ping
    end

    def self.query_samples(
      params = {},
      limit: DEFAULT_LIMIT,
      offset: 0,
      max_pages: 1,
      bbox: nil,
      rock_type: nil,
      setting: nil,
      location: nil,
      **client_options
    )
      new(**client_options).query_samples(
        params,
        limit: limit,
        offset: offset,
        max_pages: max_pages,
        bbox: bbox,
        rock_type: rock_type,
        setting: setting,
        location: location
      )
    end

    def initialize(
      base_url: ENV.fetch("GEOROC_BASE_URL", DEFAULT_BASE_URL),
      api_key: ENV["GEOROC_API_KEY"],
      connection: nil,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      timeout: DEFAULT_TIMEOUT,
      max_retries: DEFAULT_MAX_RETRIES,
      retry_delay: default_retry_delay,
      logger: Rails.logger
    )
      @base_url = base_url.to_s.strip.empty? ? DEFAULT_BASE_URL : base_url.to_s.strip
      @api_key = api_key.to_s.strip
      @connection = connection
      @open_timeout = open_timeout
      @timeout = timeout
      @max_retries = max_retries
      @retry_delay = retry_delay.to_f
      @logger = logger
    end

    def configured?
      !@api_key.empty?
    end

    def ping
      response = perform_get(PING_PATH, {})
      response.status >= 200 && response.status < 300
    rescue Error => e
      @logger&.warn("[Clients::GeorocClient] ping failed: #{e.message}")
      false
    end

    def query_samples(
      params = {},
      limit: DEFAULT_LIMIT,
      offset: 0,
      max_pages: 1,
      bbox: nil,
      rock_type: nil,
      setting: nil,
      location: nil
    )
      query_samples!(
        params,
        limit: limit,
        offset: offset,
        max_pages: max_pages,
        bbox: bbox,
        rock_type: rock_type,
        setting: setting,
        location: location
      )
    rescue Error => e
      @logger&.warn("[Clients::GeorocClient] query_samples failed: #{e.message}")
      []
    end

    def query_samples!(
      params = {},
      limit: DEFAULT_LIMIT,
      offset: 0,
      max_pages: 1,
      bbox: nil,
      rock_type: nil,
      setting: nil,
      location: nil
    )
      unless configured?
        @logger&.info("[Clients::GeorocClient] GEOROC_API_KEY not configured; skipping samples query")
        return []
      end

      page_limit = [ limit.to_i, 1 ].max
      current_offset = [ offset.to_i, 0 ].max
      pages_remaining = [ max_pages.to_i, 1 ].max

      base_params = build_query_params(
        params,
        bbox: bbox,
        rock_type: rock_type,
        setting: setting,
        location: location
      )

      collected = []
      while pages_remaining.positive?
        page_params = base_params.merge("limit" => page_limit, "offset" => current_offset)
        payload = fetch_json(SAMPLES_PATH, page_params)
        records = extract_sample_records(payload)
        break if records.empty?

        collected.concat(records)
        break if records.length < page_limit

        current_offset += page_limit
        pages_remaining -= 1
      end

      collected
    end

    private

    class RetryableStatusError < StandardError; end

    def default_retry_delay
      Rails.env.test? ? 0.0 : 0.5
    end

    def connection
      @connection ||= Faraday.new(url: @base_url) do |f|
        f.options.open_timeout = @open_timeout
        f.options.timeout = @timeout
        f.headers["Accept"] = "application/json"
        f.headers["User-Agent"] = "CeramicMaterialAssayPlatform/1.0"
        f.headers[API_KEY_HEADER] = @api_key if configured?
        f.adapter Faraday.default_adapter
      end
    end

    def build_query_params(params, bbox:, rock_type:, setting:, location:)
      query = params.is_a?(Hash) ? params.transform_keys(&:to_s) : {}
      query["rocktype"] ||= rock_type if rock_type.present?
      query["setting"] ||= setting if setting.present?
      query["location"] ||= location if location.present?

      if bbox.is_a?(Hash)
        sym = bbox.transform_keys(&:to_sym)
        query["latitude_min"]  ||= sym[:min_lat] if sym[:min_lat].present?
        query["latitude_max"]  ||= sym[:max_lat] if sym[:max_lat].present?
        query["longitude_min"] ||= sym[:min_lng] if sym[:min_lng].present?
        query["longitude_max"] ||= sym[:max_lng] if sym[:max_lng].present?
      end

      query.compact
    end

    def fetch_json(path, params)
      response = perform_get(path, params)
      parse_json!(response.body)
    end

    def perform_get(path, params)
      attempts = 0

      begin
        attempts += 1
        response = connection.get(path, params) do |req|
          req.headers[API_KEY_HEADER] = @api_key if configured?
        end

        return response if response.status >= 200 && response.status < 300

        if RETRYABLE_STATUSES.include?(response.status) && attempts <= @max_retries
          sleep_backoff(attempts)
          raise RetryableStatusError, "HTTP #{response.status}"
        end

        raise HttpError.new(
          "GEOROC API returned HTTP #{response.status}",
          status: response.status
        )
      rescue RetryableStatusError
        retry
      rescue *RETRYABLE_EXCEPTIONS => e
        if attempts <= @max_retries
          sleep_backoff(attempts)
          retry
        end

        raise NetworkError, "GEOROC API network error after #{attempts} attempt(s): #{e.class}: #{e.message}"
      rescue Faraday::Error => e
        raise NetworkError, "GEOROC API request failed: #{e.class}: #{e.message}"
      end
    end

    def sleep_backoff(attempt)
      return unless @retry_delay.positive?

      Kernel.sleep(@retry_delay * (2**(attempt - 1)))
    end

    def parse_json!(body)
      return {} if body.nil? || body.to_s.strip.empty?

      JSON.parse(body.to_s)
    rescue JSON::ParserError => e
      raise Error, "Invalid JSON from GEOROC API: #{e.message}"
    end

    def extract_sample_records(payload)
      case payload
      when Array
        payload.select { |item| item.is_a?(Hash) }
      when Hash
        raw = payload["data"] || payload["samples"] || payload["results"] || []
        Array(raw).select { |item| item.is_a?(Hash) }
      else
        []
      end
    end
  end
end
