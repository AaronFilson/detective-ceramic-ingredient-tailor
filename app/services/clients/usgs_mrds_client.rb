# frozen_string_literal: true

require "faraday"
require "json"
require "rexml/document"

module Clients
  class UsgsMrdsClient
    class Error < StandardError; end

    class HttpError < Error
      attr_reader :status

      def initialize(message, status:)
        @status = status
        super(message)
      end
    end

    class NetworkError < Error; end

    BASE_URL = "https://mrdata.usgs.gov"
    ENDPOINT_PATH = "/services/mrds"
    SOURCE_NAME = "usgs_mrds"
    DEFAULT_RADIUS_KM = 50.0
    DEFAULT_MAX_FEATURES = 50
    DEFAULT_OPEN_TIMEOUT = 5
    DEFAULT_TIMEOUT = 12
    DEFAULT_MAX_RETRIES = 2
    KM_PER_DEGREE_LAT = 111.32

    DEFAULT_COMMODITIES = %w[
      Feldspar Lithium Spodumene Talc Wollastonite Kaolin Clay Silica Quartz
      Dolomite Magnesite Olivine Boron Barite Manganese Iron Chromium Copper
      Cobalt Nickel Zircon Titanium Fluorite Pumice
    ].freeze

    COMMODITY_SYNONYMS = {
      "feldspar" => %w[feldspar albite microcline orthoclase plagioclase pegmatite],
      "lithium" => %w[lithium spodumene petalite lepidolite amblygonite],
      "spodumene" => %w[spodumene lithium petalite lepidolite],
      "talc" => %w[talc soapstone steatite pyrophyllite],
      "wollastonite" => %w[wollastonite],
      "kaolin" => %w[kaolin kaolinite halloysite china\ clay],
      "clay" => %w[clay kaolin kaolinite bentonite fire\ clay ball\ clay],
      "silica" => %w[silica quartz quartzite flint chert],
      "quartz" => %w[quartz quartzite silica],
      "dolomite" => %w[dolomite limestone carbonate],
      "magnesite" => %w[magnesite brucite dolomite],
      "olivine" => %w[olivine dunite forsterite peridotite],
      "boron" => %w[boron borate borax colemanite ulexite kernite],
      "barite" => %w[barite barium witherite],
      "manganese" => %w[manganese pyrolusite rhodonite braunite],
      "iron" => %w[iron hematite magnetite limonite goethite pyrite basalt andesite],
      "chromium" => %w[chromium chromite],
      "copper" => %w[copper chalcopyrite bornite malachite azurite],
      "cobalt" => %w[cobalt cobaltite erythrite],
      "nickel" => %w[nickel pentlandite garnierite],
      "zircon" => %w[zircon zirconium],
      "titanium" => %w[titanium rutile ilmenite anatase],
      "fluorite" => %w[fluorite fluorine fluorspar],
      "pumice" => %w[pumice perlite volcanic\ ash tephra scoria rhyolite]
    }.freeze

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

    def self.search_nearby(
      lat:,
      lng:,
      radius_km: DEFAULT_RADIUS_KM,
      commodities: DEFAULT_COMMODITIES,
      force_refresh: false,
      **options
    )
      new(**options).search_nearby(
        lat: lat,
        lng: lng,
        radius_km: radius_km,
        commodities: commodities,
        force_refresh: force_refresh
      )
    end

    def self.search_nearby!(
      lat:,
      lng:,
      radius_km: DEFAULT_RADIUS_KM,
      commodities: DEFAULT_COMMODITIES,
      force_refresh: false,
      **options
    )
      new(**options).search_nearby!(
        lat: lat,
        lng: lng,
        radius_km: radius_km,
        commodities: commodities,
        force_refresh: force_refresh
      )
    end

    def initialize(
      connection: nil,
      open_timeout: DEFAULT_OPEN_TIMEOUT,
      timeout: DEFAULT_TIMEOUT,
      max_retries: DEFAULT_MAX_RETRIES,
      max_features: DEFAULT_MAX_FEATURES,
      output_format: nil,
      retry_delay: default_retry_delay,
      logger: Rails.logger
    )
      @connection = connection
      @open_timeout = open_timeout
      @timeout = timeout
      @max_retries = max_retries
      @max_features = [ max_features.to_i, 1 ].max
      @output_format = output_format
      @retry_delay = retry_delay.to_f
      @logger = logger
    end

    def search_nearby(lat:, lng:, radius_km: DEFAULT_RADIUS_KM, commodities: DEFAULT_COMMODITIES, force_refresh: false)
      search_nearby!(
        lat: lat,
        lng: lng,
        radius_km: radius_km,
        commodities: commodities,
        force_refresh: force_refresh
      )
    rescue Error => e
      @logger&.warn("[Clients::UsgsMrdsClient] search_nearby failed for (#{lat}, #{lng}): #{e.message}")
      []
    end

    def search_nearby!(lat:, lng:, radius_km: DEFAULT_RADIUS_KM, commodities: DEFAULT_COMMODITIES, force_refresh: false)
      lat_f, lng_f = validate_coordinates!(lat, lng)
      radius_km_f = validate_radius!(radius_km)

      unless force_refresh
        cached_scope = MineralOccurrence
          .by_source(SOURCE_NAME)
          .within_radius(lat_f, lng_f, radius_km_f * 1000.0)
          .ordered_by_distance(lat_f, lng_f)

        return cached_scope.to_a if cached_scope.exists?
      end

      bbox = compute_bounding_box(lat_f, lng_f, radius_km_f)
      response = fetch_wfs_response(bbox)
      features = parse_response_features(response)
      return [] if features.empty?

      filtered = filter_and_prioritize(features, commodities, lat_f, lng_f)
      return [] if filtered.empty?

      seen_ids = {}
      persisted = []

      filtered.each do |feature|
        next if seen_ids[feature[:external_id]]

        seen_ids[feature[:external_id]] = true
        persisted << upsert_occurrence(feature)
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

    def compute_bounding_box(lat, lng, radius_km)
      lat_delta = radius_km / KM_PER_DEGREE_LAT
      cos_lat = [ Math.cos(lat * Math::PI / 180.0).abs, 0.01 ].max
      lng_delta = radius_km / (KM_PER_DEGREE_LAT * cos_lat)

      {
        min_lng: [ lng - lng_delta, -180.0 ].max.round(5),
        min_lat: [ lat - lat_delta, -90.0 ].max.round(5),
        max_lng: [ lng + lng_delta, 180.0 ].min.round(5),
        max_lat: [ lat + lat_delta, 90.0 ].min.round(5)
      }
    end

    def connection
      @connection ||= Faraday.new(url: BASE_URL) do |f|
        f.options.open_timeout = @open_timeout
        f.options.timeout = @timeout
        f.headers["Accept"] = "application/json, application/xml, text/xml"
        f.headers["User-Agent"] = "CeramicMaterialAssayPlatform/1.0"
        f.adapter Faraday.default_adapter
      end
    end

    def wfs_params(bbox)
      params = {
        service: "WFS",
        version: "1.0.0",
        request: "GetFeature",
        typeName: "mrds",
        bbox: format("%.5f,%.5f,%.5f,%.5f", bbox[:min_lng], bbox[:min_lat], bbox[:max_lng], bbox[:max_lat]),
        maxFeatures: @max_features
      }
      params[:outputFormat] = @output_format if @output_format.present?
      params
    end

    def fetch_wfs_response(bbox)
      attempts = 0
      params = wfs_params(bbox)

      begin
        attempts += 1
        response = connection.get(ENDPOINT_PATH, params)

        return response if response.status >= 200 && response.status < 300

        if retryable_status?(response.status) && attempts <= @max_retries
          sleep_backoff(attempts)
          raise RetryableStatusError, "HTTP #{response.status}"
        end

        raise HttpError.new(
          "USGS MRDS WFS returned HTTP #{response.status}",
          status: response.status
        )
      rescue RetryableStatusError
        retry
      rescue *RETRYABLE_EXCEPTIONS => e
        if attempts <= @max_retries
          sleep_backoff(attempts)
          retry
        end

        raise NetworkError, "USGS MRDS WFS network error after #{attempts} attempt(s): #{e.class}: #{e.message}"
      rescue Faraday::Error => e
        raise NetworkError, "USGS MRDS WFS request failed: #{e.class}: #{e.message}"
      end
    end

    def retryable_status?(status)
      RETRYABLE_STATUSES.include?(status)
    end

    def sleep_backoff(attempt)
      return unless @retry_delay.positive?

      Kernel.sleep(@retry_delay * (2**(attempt - 1)))
    end

    def parse_response_features(response)
      body = response.body.to_s.strip
      return [] if body.empty?

      content_type = response.headers["content-type"].to_s.downcase
      if content_type.include?("json") || body.start_with?("{", "[")
        parse_geojson_features(body)
      else
        parse_gml_features(body)
      end
    end

    def parse_geojson_features(body)
      payload = JSON.parse(body)
      raw_features =
        if payload.is_a?(Hash) && payload["features"].is_a?(Array)
          payload["features"]
        elsif payload.is_a?(Hash) && payload["type"] == "Feature"
          [ payload ]
        elsif payload.is_a?(Array)
          payload
        else
          []
        end

      raw_features.filter_map { |feature| normalize_geojson_feature(feature) }
    rescue JSON::ParserError => e
      raise Error, "Invalid JSON from USGS MRDS WFS: #{e.message}"
    end

    def normalize_geojson_feature(feature)
      return nil unless feature.is_a?(Hash)

      props = feature["properties"].is_a?(Hash) ? feature["properties"] : feature
      normalized_props = props.transform_keys { |k| k.to_s.downcase }
      geom = feature["geometry"]

      coords = extract_geojson_point(geom)
      lat = parse_float(normalized_props["latitude"] || normalized_props["lat"] || normalized_props["wgs84_lat"]) || coords&.last
      lng = parse_float(normalized_props["longitude"] || normalized_props["lon"] || normalized_props["lng"] || normalized_props["wgs84_lon"]) || coords&.first

      build_feature_record(normalized_props, lat: lat, lng: lng, fallback_id: feature["id"])
    end

    def extract_geojson_point(geom)
      return nil unless geom.is_a?(Hash)

      coords = geom["coordinates"]
      return nil unless coords.is_a?(Array)

      pair = coords.first.is_a?(Array) ? coords.first : coords
      return nil unless pair.is_a?(Array) && pair.length >= 2

      lng = parse_float(pair[0])
      lat = parse_float(pair[1])
      return nil if lat.nil? || lng.nil?

      [ lng, lat ]
    end

    def parse_gml_features(body)
      doc = REXML::Document.new(body)
      root = doc.root
      return [] if root.nil?

      if root.name.downcase.include?("exception")
        message = root.elements.to_a(".//*").filter_map { |el| present_string(el.text) }.first
        raise Error, "USGS MRDS WFS service exception: #{message || root.name}"
      end

      member_nodes = collect_feature_nodes(root)
      member_nodes.filter_map { |node| normalize_gml_node(node) }
    rescue REXML::ParseException => e
      raise Error, "Invalid GML/XML from USGS MRDS WFS: #{e.message}"
    end

    def collect_feature_nodes(root)
      nodes = []
      root.each_element do |child|
        local = child.name.downcase
        if local == "featuremember"
          child.each_element { |feature_el| nodes << feature_el }
        elsif local == "featuremembers"
          child.each_element { |feature_el| nodes << feature_el }
        elsif local == "mrds"
          nodes << child
        end
      end
      nodes
    end

    def normalize_gml_node(node)
      props = {}
      gml_coords = nil

      node.each_element do |child|
        local = child.name.downcase
        if child.has_elements?
          gml_coords ||= extract_gml_coordinates(child)
        else
          value = present_string(child.text)
          props[local] = value if value.present?
        end
      end

      lat = parse_float(props["latitude"] || props["lat"] || props["wgs84_lat"]) || gml_coords&.last
      lng = parse_float(props["longitude"] || props["lon"] || props["lng"] || props["wgs84_lon"]) || gml_coords&.first
      fid = node.attributes["fid"] || node.attributes["gml:id"] || node.attributes["id"]

      build_feature_record(props, lat: lat, lng: lng, fallback_id: fid)
    end

    def extract_gml_coordinates(element)
      coord_text = nil
      pos_text = nil

      element.each_element(".//*") do |el|
        local = el.name.downcase
        if local == "coordinates" && el.text.present?
          coord_text = el.text.strip
          break
        elsif local == "pos" && el.text.present?
          pos_text ||= el.text.strip
        end
      end

      if coord_text.present?
        first_tuple = coord_text.split(/\s+/).first.to_s
        parts = first_tuple.split(",")
        if parts.length >= 2
          lng = parse_float(parts[0])
          lat = parse_float(parts[1])
          return [ lng, lat ] if lat && lng
        end
      elsif pos_text.present?
        parts = pos_text.split(/\s+/)
        if parts.length >= 2
          lng = parse_float(parts[0])
          lat = parse_float(parts[1])
          return [ lng, lat ] if lat && lng
        end
      end

      nil
    end

    def build_feature_record(props, lat:, lng:, fallback_id: nil)
      return nil if lat.nil? || lng.nil? || !lat.between?(-90.0, 90.0) || !lng.between?(-180.0, 180.0)

      ext_id = normalize_external_id(
        props["dep_id"] || props["mrds_id"] || props["site_id"] || props["id"] || fallback_id
      )
      name = present_string(props["site_name"] || props["name"])
      return nil if ext_id.nil? || name.nil?

      commodities = extract_terms(
        props["commod1"],
        props["commod2"],
        props["commod3"],
        props["commodity"],
        props["commodities"]
      )
      minerals = extract_terms(
        props["ore"],
        props["gangue"],
        props["minerals"],
        props["rock_type"]
      )
      deposit_type = present_string(
        props["dep_type"] || props["model_name"] || props["deposit_type"] || props["dev_stat"]
      )

      raw_metadata = {
        "dep_id" => ext_id,
        "dev_stat" => present_string(props["dev_stat"]),
        "oper_type" => present_string(props["oper_type"]),
        "model_name" => present_string(props["model_name"]),
        "state" => present_string(props["state"]),
        "county" => present_string(props["county"]),
        "score" => present_string(props["score"]),
        "url" => present_string(props["url"]) || "https://mrdata.usgs.gov/mrds/show-mrds.php?dep_id=#{ext_id}"
      }.compact

      {
        external_id: ext_id,
        name: name,
        latitude: lat,
        longitude: lng,
        commodities: commodities,
        minerals: minerals,
        deposit_type: deposit_type,
        raw_metadata: raw_metadata
      }
    end

    def normalize_external_id(raw)
      str = present_string(raw)
      return nil if str.nil?

      str.sub(/\Amrds\./i, "")
    end

    def extract_terms(*values)
      values.flat_map do |val|
        case val
        when Array
          val.flat_map { |v| extract_terms(v) }
        when String
          val.split(/[,;|\/]+/).map(&:strip).reject(&:empty?)
        else
          []
        end
      end.uniq
    end

    def filter_and_prioritize(features, commodities, query_lat, query_lng)
      allowed = Array(commodities).map { |c| c.to_s.strip.downcase }.reject(&:empty?)
      return features if allowed.empty?

      search_tokens = allowed.flat_map { |c| COMMODITY_SYNONYMS.fetch(c, [ c ]) }.uniq

      scored = features.filter_map do |feature|
        score = ceramic_relevance_score(feature, search_tokens)
        next unless score.positive?

        dist = squared_deg_distance(query_lat, query_lng, feature[:latitude], feature[:longitude])
        [ feature, score, dist ]
      end

      scored
        .sort_by { |(_, score, dist)| [ -score, dist ] }
        .map(&:first)
    end

    def ceramic_relevance_score(feature, search_tokens)
      haystack = (
        Array(feature[:commodities]) +
        Array(feature[:minerals]) +
        [ feature[:deposit_type], feature[:name] ].compact
      ).map { |t| t.to_s.downcase }

      search_tokens.count do |token|
        haystack.any? { |term| term.include?(token) || (term.length >= 3 && token.include?(term)) }
      end
    end

    def squared_deg_distance(lat1, lng1, lat2, lng2)
      ((lat1 - lat2)**2) + ((lng1 - lng2)**2)
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
