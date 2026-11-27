# frozen_string_literal: true

require "faraday"
require "json"
require "uri"

module Clients
  # Pushes a serialized UserSample / AssayResult directly to a user's Glazecalc
  # account via POST /api/materials using a transient personal API token.
  # The token is never persisted or written to logs.
  class GlazecalcPushClient
    DEFAULT_BASE_URL = "https://glazecalc.com"
    ENDPOINT_PATH = "api/materials"
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_TIMEOUT = 12

    RECORD_FIELDS = %w[
      name
      fields
      percentmole
      loi
      molecularweight
      equivalent
      formulaweight
      rawformula
      notes
      relatedTo
    ].freeze

    NETWORK_EXCEPTIONS = [
      Faraday::TimeoutError,
      Faraday::ConnectionFailed,
      Faraday::SSLError,
      Faraday::Error,
      Timeout::Error,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      SocketError
    ].freeze

    Result = Struct.new(
      :success,
      :status,
      :material_id,
      :material_name,
      :message,
      :response_body,
      keyword_init: true
    ) do
      def success?
        !!success
      end
    end

    def self.call(assay_result_or_sample, api_token:, base_url: DEFAULT_BASE_URL, **options)
      new(
        assay_result_or_sample,
        api_token: api_token,
        base_url: base_url,
        **options
      ).call
    end

    def initialize(
      assay_result_or_sample,
      api_token:,
      base_url: DEFAULT_BASE_URL,
      connection: nil,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      timeout: DEFAULT_TIMEOUT
    )
      @assay_result_or_sample = assay_result_or_sample
      @api_token = api_token.to_s.strip
      @raw_base_url = base_url.nil? ? DEFAULT_BASE_URL : base_url.to_s.strip
      @connection = connection
      @open_timeout = open_timeout
      @timeout = timeout
    end

    def call
      return failure("Glazecalc API token is required. Generate a token with \"Read and change\" write scope in Glazecalc.") if @api_token.empty?

      normalized_url = validate_and_normalize_base_url(@raw_base_url)
      return failure("Invalid Glazecalc URL. Provide a valid http:// or https:// base URL.") if normalized_url.nil?

      payload = build_payload
      response = perform_request(normalized_url, payload)
      handle_response(response, payload["name"])
    rescue ArgumentError => e
      failure(e.message)
    rescue Faraday::TimeoutError, Timeout::Error
      failure("Request to Glazecalc timed out after #{@timeout}s. Check the server URL and try again.")
    rescue *NETWORK_EXCEPTIONS => e
      if timeout_exception?(e)
        failure("Request to Glazecalc timed out after #{@timeout}s. Check the server URL and try again.")
      else
        failure("Could not connect to Glazecalc: #{sanitize_message(e.message)}")
      end
    end

    private

    def validate_and_normalize_base_url(raw)
      return nil if raw.empty?

      uri = URI.parse(raw)
      return nil unless uri.is_a?(URI::HTTP)
      return nil unless %w[http https].include?(uri.scheme)
      return nil if uri.host.nil? || uri.host.strip.empty?

      "#{raw.sub(%r{/+\z}, '')}/"
    rescue URI::InvalidURIError
      nil
    end

    def build_payload
      serialized = Exporters::GlazecalcMaterialSerializer.call(@assay_result_or_sample)
      serialized.slice(*RECORD_FIELDS)
    end

    def perform_request(normalized_url, payload)
      conn = build_connection(normalized_url)
      conn.post(ENDPOINT_PATH) do |req|
        req.headers["Authorization"] = "Bearer #{@api_token}"
        req.headers["Content-Type"] = "application/json"
        req.headers["Accept"] = "application/json"
        req.headers["User-Agent"] = "CeramicMaterialAssayPlatform/1.0"
        req.body = JSON.generate(payload)
      end
    end

    def build_connection(normalized_url)
      return @connection if @connection

      Faraday.new(url: normalized_url) do |f|
        f.options.open_timeout = @open_timeout
        f.options.timeout = @timeout
        f.adapter Faraday.default_adapter
      end
    end

    def handle_response(response, fallback_name)
      status = response.status.to_i
      parsed_body = parse_json_safely(response.body)
      material_id = extract_material_id(parsed_body)
      material_name = extract_material_name(parsed_body) || fallback_name

      case status
      when 200, 201
        id_suffix = material_id.present? ? " (ID: #{material_id})" : ""
        Result.new(
          success: true,
          status: status,
          material_id: material_id,
          material_name: material_name,
          message: "Successfully pushed \"#{material_name}\" to Glazecalc#{id_suffix}.",
          response_body: parsed_body
        )
      when 401, 403
        detail = extract_error_detail(parsed_body)
        suffix = detail.present? ? " (#{detail})" : ""
        failure(
          "Glazecalc authentication failed (HTTP #{status}). Ensure your API token is valid and granted \"Read and change\" write scope#{suffix}.",
          status: status,
          material_name: material_name,
          response_body: parsed_body
        )
      when 409, 422
        detail = extract_error_detail(parsed_body)
        suffix = detail.present? ? ": #{detail}" : ". Check for duplicate material names or invalid fields."
        failure(
          "Glazecalc rejected the material (HTTP #{status})#{suffix}",
          status: status,
          material_name: material_name,
          response_body: parsed_body
        )
      else
        detail = extract_error_detail(parsed_body)
        suffix = detail.present? ? ": #{detail}" : "."
        failure(
          "Glazecalc returned HTTP #{status}#{suffix}",
          status: status,
          material_name: material_name,
          response_body: parsed_body
        )
      end
    end

    def parse_json_safely(body)
      text = body.to_s.strip
      return nil if text.empty?

      JSON.parse(text)
    rescue JSON::ParserError
      text
    end

    def extract_material_id(parsed_body)
      return nil unless parsed_body.is_a?(Hash)

      parsed_body["id"] ||
        parsed_body["_id"] ||
        parsed_body["materialId"] ||
        parsed_body.dig("material", "id") ||
        parsed_body.dig("material", "_id") ||
        parsed_body.dig("data", "id") ||
        parsed_body.dig("record", "id")
    end

    def extract_material_name(parsed_body)
      return nil unless parsed_body.is_a?(Hash)

      parsed_body["name"] ||
        parsed_body.dig("material", "name") ||
        parsed_body.dig("data", "name") ||
        parsed_body.dig("record", "name")
    end

    def extract_error_detail(parsed_body)
      case parsed_body
      when Hash
        detail = parsed_body["error"] || parsed_body["message"] || parsed_body["detail"]
        if detail.is_a?(Array)
          detail.map(&:to_s).join("; ")
        elsif detail.is_a?(Hash)
          detail["message"] || detail.values.map(&:to_s).join("; ")
        elsif detail.present?
          detail.to_s
        elsif parsed_body["errors"].is_a?(Array)
          parsed_body["errors"].map { |err| err.is_a?(Hash) ? (err["message"] || err.values.join(": ")) : err.to_s }.join("; ")
        end
      when String
        parsed_body.truncate(200)
      end
    end

    def timeout_exception?(error)
      return true if error.is_a?(Faraday::TimeoutError) || error.is_a?(Timeout::Error)
      return true if error.respond_to?(:wrapped_exception) && error.wrapped_exception.is_a?(Timeout::Error)

      error.message.to_s.match?(/execution expired|timed?\s*out/i)
    end

    def sanitize_message(text)
      msg = text.to_s
      return msg if @api_token.empty?

      msg.gsub(@api_token, "[REDACTED]")
    end

    def failure(message, status: nil, material_name: nil, response_body: nil)
      Result.new(
        success: false,
        status: status,
        material_id: nil,
        material_name: material_name,
        message: message,
        response_body: response_body
      )
    end
  end
end
