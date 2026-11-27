# frozen_string_literal: true

require "csv"
require "digest"

module Ingestion
  class BaseCsvImporter
    OXIDE_PATTERNS = {
      "SiO2"   => /\Asio2(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "Al2O3"  => /\Aal2o3(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "Fe2O3T" => /\Afe2o3(?:t|_?tot(?:al)?)(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes))*\z/,
      "Fe2O3"  => /\Afe2o3(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes))*\z/,
      "FeO"    => /\Afeo(?:t|_?tot(?:al)?)?(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes))*\z/,
      "CaO"    => /\Acao(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "MgO"    => /\Amgo(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "Na2O"   => /\Ana2o(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "K2O"    => /\Ak2o(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "TiO2"   => /\Atio2(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "P2O5"   => /\Ap2o5(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "MnO"    => /\Amno(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "LOI"    => /\A(?:loi|loss_on_ignition)(?:_(?:wt_?pct|wt|pct|percent))*\z/
    }.freeze

    VOLATILE_KEYS = %w[h2o_plus h2o_minus h2o_tot h2o co2].freeze

    LATITUDE_KEYS = %w[latitude lat lat_dd lat_wgs84 dec_lat latitude_dd y].freeze
    LONGITUDE_KEYS = %w[longitude lng lon long lon_dd lng_dd long_dd lon_wgs84 dec_long dec_lon longitude_dd x].freeze

    MISSING_TOKENS = /\A(?:|na|n\/a|nd|bdl|n|null|none|nan|--+|-)\z/i

    def initialize(input, source: default_source)
      @input = input
      @source = source.to_s
    end

    def call
      created = 0
      updated = 0
      skipped = 0
      errors = []

      csv_content = read_input_content
      csv_body = strip_preamble(csv_content)
      col_sep = detect_separator(csv_body)

      ReferenceAssay.transaction do
        CSV.parse(csv_body, headers: true, col_sep: col_sep, liberal_parsing: true).each_with_index do |row, idx|
          row_num = idx + 2
          normalized_row = normalize_row_headers(row)

          lat = extract_coordinate(normalized_row, LATITUDE_KEYS, -90.0..90.0)
          lng = extract_coordinate(normalized_row, LONGITUDE_KEYS, -180.0..180.0)
          if lat.nil? || lng.nil?
            skipped += 1
            errors << { row: row_num, reason: "Missing or invalid latitude/longitude" }
            next
          end

          raw_oxides = extract_oxides(normalized_row)
          if raw_oxides["SiO2"].nil? || !raw_oxides["SiO2"].positive? ||
              raw_oxides["Al2O3"].nil? || !raw_oxides["Al2O3"].positive?
            skipped += 1
            errors << { row: row_num, reason: "Missing valid numeric SiO2 or Al2O3" }
            next
          end

          normalized_oxides = CeramicOxides.normalize(raw_oxides)
          if normalized_oxides.nil?
            skipped += 1
            errors << { row: row_num, reason: "Oxide total must be positive" }
            next
          end

          rock_type = extract_rock_type(normalized_row)
          external_id = extract_external_id(normalized_row, lat, lng, rock_type, normalized_oxides)
          raw_metadata = build_raw_metadata(row)

          assay = ReferenceAssay.find_or_initialize_by(source: @source, external_id: external_id)
          was_new = assay.new_record?
          assay.assign_attributes(
            rock_type: rock_type,
            location: Geolocatable.factory.point(lng, lat),
            oxides: normalized_oxides,
            raw_metadata: raw_metadata
          )
          assay.save!

          if was_new
            created += 1
          else
            updated += 1
          end
        end
      end

      ImportResult.new(
        imported: created + updated,
        created: created,
        updated: updated,
        skipped: skipped,
        errors: errors
      )
    end

    protected

    def default_source
      raise NotImplementedError, "#{self.class} must define #default_source"
    end

    def external_id_keys
      %w[external_id sample_id lab_id field_id id]
    end

    def rock_type_keys
      %w[rock_type rock_name lithology material sample_type]
    end

    def strip_preamble(content)
      content
    end

    private

    def read_input_content
      raw = if @input.respond_to?(:read)
        @input.read
      else
        File.read(@input.to_s, encoding: "bom|utf-8")
      end
      raw.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").sub(/\A\uFEFF/, "")
    end

    def detect_separator(content)
      first_line = content.lines.find { |l| !l.strip.empty? } || ""
      first_line.include?("\t") && !first_line.include?(",") ? "\t" : ","
    end

    def canonicalize_header(header)
      return nil if header.nil?

      header
        .to_s
        .sub(/\A\uFEFF/, "")
        .strip
        .gsub("+", "_plus")
        .gsub(/h2o\s*-/i, "h2o_minus")
        .gsub("%", "_pct")
        .downcase
        .gsub(/[^a-z0-9]+/, "_")
        .gsub(/\A_+|_+\z/, "")
    end

    def normalize_row_headers(row)
      result = {}
      row.each do |header, value|
        key = canonicalize_header(header)
        next if key.nil? || key.empty?

        # Keep first non-blank value when duplicate headers normalize similarly
        if !result.key?(key) || result[key].to_s.strip.empty?
          result[key] = value
        end
      end
      result
    end

    def extract_coordinate(normalized_row, candidate_keys, range)
      candidate_keys.each do |key|
        next unless normalized_row.key?(key)

        val = parse_float(normalized_row[key], allow_negative: true)
        return val if val && range.cover?(val)
      end
      nil
    end

    def extract_oxides(normalized_row)
      direct = {}
      fe2o3_total = nil
      fe2o3_ferric = nil
      feo_val = nil

      # Pass 1: Direct oxide weight% columns
      normalized_row.each do |key, raw_val|
        val = parse_float(raw_val, allow_negative: false)
        next if val.nil?

        if key.match?(OXIDE_PATTERNS["Fe2O3T"])
          fe2o3_total ||= val
        elsif key.match?(OXIDE_PATTERNS["Fe2O3"])
          fe2o3_ferric ||= val
        elsif key.match?(OXIDE_PATTERNS["FeO"])
          feo_val ||= val
        else
          OXIDE_PATTERNS.each do |oxide, pattern|
            next if oxide == "Fe2O3T" || oxide == "Fe2O3" || oxide == "FeO"

            if key.match?(pattern)
              direct[oxide] ||= val
              break
            end
          end
        end
      end

      # Resolve iron oxide hierarchy: Fe2O3T > Fe2O3 + FeO*1.1113 > FeO*1.1113
      if !fe2o3_total.nil?
        direct["Fe2O3"] = fe2o3_total
      elsif !fe2o3_ferric.nil? || !feo_val.nil?
        direct["Fe2O3"] = (fe2o3_ferric || 0.0) + ((feo_val || 0.0) * CeramicOxides::FEO_TO_FE2O3_FACTOR)
      end

      # Pass 2: Elemental wt% or ppm columns for any oxide not yet populated
      CeramicOxides::ELEMENT_TO_OXIDE_FACTORS.each do |element, spec|
        oxide = spec[:oxide]
        next unless direct[oxide].nil?

        el_wt_pct = extract_element_wt_pct(normalized_row, element)
        next if el_wt_pct.nil?

        direct[oxide] = el_wt_pct * spec[:factor]
      end

      # Pass 3: Fallback LOI from H2O+/H2O-/CO2 if LOI was not explicitly provided
      if direct["LOI"].nil?
        volatiles = VOLATILE_KEYS.filter_map { |vk| parse_float(normalized_row[vk], allow_negative: false) }
        direct["LOI"] = volatiles.sum if volatiles.any?
      end

      direct
    end

    def extract_element_wt_pct(normalized_row, element)
      el = element.downcase
      ppm_pattern = /\A#{el}(?:_(?:icp|icpms|oes|aes|xrf|ms|tot|total))*_ppm\z/
      pct_pattern = /\A#{el}(?:_(?:icp|icpms|oes|aes|xrf|ms|tot|total))*_(?:wt_?pct|wt|pct|percent)\z/
      bare_pattern = /\A#{el}\z/

      # Prefer explicit wt% column over ppm column over bare column
      normalized_row.each do |key, raw_val|
        next unless key.match?(pct_pattern)

        val = parse_float(raw_val, allow_negative: false)
        return val unless val.nil?
      end

      normalized_row.each do |key, raw_val|
        next unless key.match?(ppm_pattern)

        val = parse_float(raw_val, allow_negative: false)
        return val / 10_000.0 unless val.nil?
      end

      normalized_row.each do |key, raw_val|
        next unless key.match?(bare_pattern)

        val = parse_float(raw_val, allow_negative: false)
        next if val.nil?

        # Bare element column: > 100 indicates ppm; <= 100 indicates wt%
        return val > 100.0 ? (val / 10_000.0) : val
      end

      nil
    end

    def extract_rock_type(normalized_row)
      rock_type_keys.each do |key|
        val = normalized_row[key]&.to_s&.strip
        return val.downcase if val && !val.empty? && !val.match?(MISSING_TOKENS)
      end
      nil
    end

    def extract_external_id(normalized_row, lat, lng, rock_type, normalized_oxides)
      external_id_keys.each do |key|
        val = normalized_row[key]&.to_s&.strip
        return val if val && !val.empty? && !val.match?(MISSING_TOKENS)
      end

      payload = [
        @source,
        format("%.6f", lat),
        format("%.6f", lng),
        rock_type.to_s,
        CeramicOxides::KEYS.map { |k| format("%.4f", normalized_oxides[k].to_f) }.join(",")
      ].join("|")
      "sha256:#{Digest::SHA256.hexdigest(payload)[0, 24]}"
    end

    def parse_float(raw_val, allow_negative: false)
      return nil if raw_val.nil?

      str = raw_val.to_s.strip
      return nil if str.empty? || str.match?(MISSING_TOKENS)
      return nil if str.start_with?("<", ">")

      val = Float(str)
      return nil if val.nan? || val.infinite?
      return nil if !allow_negative && val.negative?

      val
    rescue ArgumentError, TypeError
      nil
    end

    def build_raw_metadata(row)
      row.to_h.each_with_object({}) do |(k, v), acc|
        next if k.nil? || k.to_s.strip.empty?

        acc[k.to_s.strip] = v.is_a?(String) ? v.strip : v
      end
    end
  end
end
