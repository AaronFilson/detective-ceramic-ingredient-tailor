# frozen_string_literal: true

require "csv"
require "faraday"
require "json"
require "stringio"
require "uri"

module Ingestion
  class UsgsSciencebaseFetcher
    class Error < StandardError; end

    class HttpError < Error
      attr_reader :status

      def initialize(message, status:)
        @status = status
        super(message)
      end
    end

    class NetworkError < Error; end

    FetchResult = Struct.new(
      :imported,
      :created,
      :updated,
      :skipped,
      :matched_rows,
      :filtered_out_rows,
      :files_processed,
      :discovered_urls,
      :bbox,
      :errors,
      keyword_init: true
    )

    CATALOG_URL = "https://www.sciencebase.gov/catalog/items"
    DEFAULT_QUERY = "National Geochemical Database clay rock"
    DEFAULT_MAX_ITEMS = 20
    DEFAULT_MAX_FILES = 5
    DEFAULT_OPEN_TIMEOUT = 10
    DEFAULT_TIMEOUT = 30
    DEFAULT_MAX_RETRIES = 2
    MAX_REDIRECTS = 3
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

    REGION_BBOXES = {
      "WA"  => { min_lat: 45.54, min_lng: -124.85, max_lat: 49.00, max_lng: -116.91 }.freeze,
      "OR"  => { min_lat: 41.99, min_lng: -124.57, max_lat: 46.29, max_lng: -116.46 }.freeze,
      "PNW" => { min_lat: 41.99, min_lng: -124.85, max_lat: 49.00, max_lng: -116.46 }.freeze,
      "CA"  => { min_lat: 32.53, min_lng: -124.48, max_lat: 42.01, max_lng: -114.13 }.freeze,
      "ID"  => { min_lat: 41.99, min_lng: -117.24, max_lat: 49.00, max_lng: -111.04 }.freeze,
      "MT"  => { min_lat: 44.36, min_lng: -116.05, max_lat: 49.00, max_lng: -104.04 }.freeze,
      "CO"  => { min_lat: 36.99, min_lng: -109.06, max_lat: 41.00, max_lng: -102.04 }.freeze,
      "NC"  => { min_lat: 33.84, min_lng: -84.32,  max_lat: 36.59, max_lng: -75.46 }.freeze,
      "GA"  => { min_lat: 30.36, min_lng: -85.61,  max_lat: 35.00, max_lng: -80.84 }.freeze,
      "US"  => { min_lat: 24.39, min_lng: -125.00, max_lat: 49.38, max_lng: -66.93 }.freeze
    }.freeze

    def self.parse_bbox(region_or_bbox)
      case region_or_bbox
      when Hash
        normalize_bbox_hash(region_or_bbox)
      when String, Symbol
        raw = region_or_bbox.to_s.strip
        raise ArgumentError, "region_or_bbox is required" if raw.empty?

        preset = REGION_BBOXES[raw.upcase]
        return preset.dup if preset

        parts = raw.split(",").map(&:strip)
        unless parts.length == 4
          raise ArgumentError, "Unknown region preset '#{raw}' and invalid bbox format (expected 'min_lat,min_lng,max_lat,max_lng')"
        end

        min_lat, min_lng, max_lat, max_lng = parts.map { |p| Float(p) }
        validate_bbox!(min_lat: min_lat, min_lng: min_lng, max_lat: max_lat, max_lng: max_lng)
      else
        raise ArgumentError, "Unsupported region_or_bbox: #{region_or_bbox.inspect}"
      end
    rescue ArgumentError
      raise
    rescue TypeError => e
      raise ArgumentError, "Invalid bbox value: #{e.message}"
    end

    def self.normalize_bbox_hash(hash)
      sym = hash.transform_keys(&:to_sym)
      min_lat = Float(sym.fetch(:min_lat))
      min_lng = Float(sym.fetch(:min_lng))
      max_lat = Float(sym.fetch(:max_lat))
      max_lng = Float(sym.fetch(:max_lng))
      validate_bbox!(min_lat: min_lat, min_lng: min_lng, max_lat: max_lat, max_lng: max_lng)
    rescue KeyError => e
      raise ArgumentError, "Missing bbox key: #{e.message}"
    end

    def self.validate_bbox!(min_lat:, min_lng:, max_lat:, max_lng:)
      unless [ min_lat, min_lng, max_lat, max_lng ].all? { |v| v.is_a?(Numeric) && v.finite? } &&
          min_lat.between?(-90.0, 90.0) && max_lat.between?(-90.0, 90.0) &&
          min_lng.between?(-180.0, 180.0) && max_lng.between?(-180.0, 180.0) &&
          min_lat < max_lat && min_lng < max_lng
        raise ArgumentError, "Invalid bounding box coordinates: min_lat=#{min_lat}, min_lng=#{min_lng}, max_lat=#{max_lat}, max_lng=#{max_lng}"
      end

      {
        min_lat: min_lat.to_f,
        min_lng: min_lng.to_f,
        max_lat: max_lat.to_f,
        max_lng: max_lng.to_f
      }
    end

    def self.call(**options)
      new(**options).call
    end

    def initialize(
      region: "PNW",
      bbox: nil,
      query: DEFAULT_QUERY,
      catalog_url: CATALOG_URL,
      csv_urls: nil,
      max_items: DEFAULT_MAX_ITEMS,
      max_files: DEFAULT_MAX_FILES,
      source: "usgs_ngdb",
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      timeout: DEFAULT_TIMEOUT,
      max_retries: DEFAULT_MAX_RETRIES,
      retry_delay: default_retry_delay,
      logger: Rails.logger
    )
      @bbox = self.class.parse_bbox(bbox || region)
      @query = query
      @catalog_url = catalog_url
      @csv_urls = csv_urls
      @max_items = max_items
      @max_files = max_files
      @source = source
      @open_timeout = open_timeout
      @timeout = timeout
      @max_retries = max_retries
      @retry_delay = retry_delay.to_f
      @logger = logger
    end

    def call
      urls = @csv_urls ? Array(@csv_urls).first(@max_files) : discover_csv_urls

      imported = 0
      created = 0
      updated = 0
      skipped = 0
      matched_rows = 0
      filtered_out_rows = 0
      files_processed = 0
      errors = []

      urls.each do |url|
        csv_body = fetch_csv_body(url)
        filtered = filter_csv_to_bbox(csv_body, @bbox)
        matched_rows += filtered[:matched_rows]
        filtered_out_rows += filtered[:filtered_out_rows]
        files_processed += 1

        next if filtered[:matched_rows].zero?

        import_result = Ingestion::UsgsCsvImporter.new(
          StringIO.new(filtered[:csv]),
          source: @source,
          bulk: true
        ).call

        imported += import_result.imported
        created += import_result.created
        updated += import_result.updated
        skipped += import_result.skipped
        errors.concat(import_result.errors.map { |err| err.merge(url: url) })
      rescue Error, CSV::MalformedCSVError => e
        @logger&.warn("[Ingestion::UsgsSciencebaseFetcher] failed to process #{url}: #{e.message}")
        errors << { url: url, reason: e.message }
      end

      FetchResult.new(
        imported: imported,
        created: created,
        updated: updated,
        skipped: skipped,
        matched_rows: matched_rows,
        filtered_out_rows: filtered_out_rows,
        files_processed: files_processed,
        discovered_urls: urls,
        bbox: @bbox,
        errors: errors
      )
    end

    def discover_csv_urls
      response_body = http_get_with_retries(
        @catalog_url,
        params: { q: @query, format: "json", max: @max_items },
        accept: "application/json"
      )
      payload = parse_json!(response_body)
      extract_csv_urls(payload).first(@max_files)
    end

    private

    class RetryableStatusError < StandardError; end

    def default_retry_delay
      Rails.env.test? ? 0.0 : 0.5
    end

    def extract_csv_urls(payload)
      return [] unless payload.is_a?(Hash)

      items = Array(payload["items"])
      urls = []

      items.each do |item|
        next unless item.is_a?(Hash)

        Array(item["files"]).each do |file|
          next unless file.is_a?(Hash)

          url = file["url"].to_s.strip
          next unless valid_http_url?(url)
          next unless csv_attachment?(name: file["name"], content_type: file["contentType"], url: url)

          urls << url
        end

        Array(item["webLinks"]).each do |link|
          next unless link.is_a?(Hash)

          uri = link["uri"].to_s.strip
          next unless valid_http_url?(uri)
          next unless uri.match?(/\.(?:csv|tsv)(?:\?|\z)/i)

          urls << uri
        end
      end

      urls.uniq
    end

    def csv_attachment?(name:, content_type:, url:)
      return true if content_type.to_s.match?(/text\/csv|tab-separated-values/i)
      return true if name.to_s.match?(/\.(?:csv|tsv)\z/i)
      return true if url.to_s.match?(/\.(?:csv|tsv)(?:\?|\z)/i)

      false
    end

    def valid_http_url?(url)
      uri = URI.parse(url)
      uri.is_a?(URI::HTTP) || uri.is_a?(URI::HTTPS)
    rescue URI::InvalidURIError
      false
    end

    def fetch_csv_body(url)
      http_get_with_retries(url, accept: "text/csv, text/plain, */*")
    end

    def http_get_with_retries(url, params: nil, accept: "*/*", redirects_remaining: MAX_REDIRECTS)
      attempts = 0

      begin
        attempts += 1
        conn = Faraday.new do |f|
          f.options.open_timeout = @open_timeout
          f.options.timeout = @timeout
          f.headers["Accept"] = accept
          f.headers["User-Agent"] = "CeramicMaterialAssayPlatform/1.0"
          f.adapter Faraday.default_adapter
        end

        response = params ? conn.get(url, params) : conn.get(url)

        if response.status >= 200 && response.status < 300
          return response.body.to_s
        end

        if [ 301, 302, 303, 307, 308 ].include?(response.status) &&
            response.headers["location"].present? &&
            redirects_remaining.positive?
          redirect_url = URI.join(url, response.headers["location"]).to_s
          return http_get_with_retries(
            redirect_url,
            accept: accept,
            redirects_remaining: redirects_remaining - 1
          )
        end

        if RETRYABLE_STATUSES.include?(response.status) && attempts <= @max_retries
          sleep_backoff(attempts)
          raise RetryableStatusError, "HTTP #{response.status}"
        end

        raise HttpError.new(
          "USGS ScienceBase request to #{url} returned HTTP #{response.status}",
          status: response.status
        )
      rescue RetryableStatusError
        retry
      rescue *RETRYABLE_EXCEPTIONS => e
        if attempts <= @max_retries
          sleep_backoff(attempts)
          retry
        end

        raise NetworkError, "USGS ScienceBase network error after #{attempts} attempt(s): #{e.class}: #{e.message}"
      rescue Faraday::Error => e
        raise NetworkError, "USGS ScienceBase request failed: #{e.class}: #{e.message}"
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
      raise Error, "Invalid JSON from USGS ScienceBase Catalog API: #{e.message}"
    end

    def filter_csv_to_bbox(csv_body, bbox)
      cleaned = csv_body.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").sub(/\A\uFEFF/, "")
      first_line = cleaned.lines.find { |l| !l.strip.empty? } || ""
      col_sep = first_line.include?("\t") && !first_line.include?(",") ? "\t" : ","

      table = CSV.parse(cleaned, headers: true, col_sep: col_sep, liberal_parsing: true)
      headers = table.headers
      return { csv: "", matched_rows: 0, filtered_out_rows: 0 } if headers.nil? || headers.empty?

      lat_header = find_coordinate_header(headers, Ingestion::BaseCsvImporter::LATITUDE_KEYS)
      lng_header = find_coordinate_header(headers, Ingestion::BaseCsvImporter::LONGITUDE_KEYS)
      if lat_header.nil? || lng_header.nil?
        return { csv: "", matched_rows: 0, filtered_out_rows: table.size }
      end

      matched = 0
      filtered_out = 0

      output = CSV.generate(col_sep: col_sep) do |csv|
        csv << headers
        table.each do |row|
          lat = parse_coord(row[lat_header])
          lng = parse_coord(row[lng_header])

          if lat && lng &&
              lat.between?(bbox[:min_lat], bbox[:max_lat]) &&
              lng.between?(bbox[:min_lng], bbox[:max_lng])
            csv << headers.map { |h| row[h] }
            matched += 1
          else
            filtered_out += 1
          end
        end
      end

      { csv: output, matched_rows: matched, filtered_out_rows: filtered_out }
    end

    def find_coordinate_header(headers, candidate_keys)
      canonical_map = headers.compact.each_with_object({}) do |header, acc|
        canonical = canonicalize_header(header)
        acc[canonical] ||= header unless canonical.empty?
      end

      candidate_keys.each do |key|
        return canonical_map[key] if canonical_map.key?(key)
      end
      nil
    end

    def canonicalize_header(header)
      header
        .to_s
        .sub(/\A\uFEFF/, "")
        .strip
        .downcase
        .gsub(/[^a-z0-9]+/, "_")
        .gsub(/\A_+|_+\z/, "")
    end

    def parse_coord(raw_val)
      return nil if raw_val.nil?

      str = raw_val.to_s.strip
      return nil if str.empty?

      val = Float(str)
      return nil if val.nan? || val.infinite?

      val
    rescue ArgumentError, TypeError
      nil
    end
  end
end
