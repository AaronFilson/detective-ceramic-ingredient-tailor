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

    MINOR_OXIDE_PATTERNS = {
      "Li2O"  => /\Ali2o(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "B2O3"  => /\Ab2o3(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "SrO"   => /\Asro(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "BaO"   => /\Abao(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "ZnO"   => /\Azno(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "ZrO2"  => /\Azro2(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "SnO2"  => /\Asno2(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "Cr2O3" => /\Acr2o3(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "CuO"   => /\Acuo(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "CoO"   => /\Acoo(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "NiO"   => /\Anio(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "V2O5"  => /\Av2o5(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "CeO2"  => /\Aceo2(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "Pr2O3" => /\Apr2o3(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "SO3"   => /\Aso3(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/
    }.freeze

    MINOR_OXIDE_MIN_WT_PCT = 0.01
    FLUORINE_BARE_WT_PCT_MAX = 10.0

    VOLATILE_KEYS = %w[h2o_plus h2o_minus h2o_tot h2o co2].freeze
    VOLATILE_PATTERNS = VOLATILE_KEYS.map do |vk|
      /\A#{vk}(?:_(?:wt_?pct|wt|pct|percent))*\z/
    end.freeze

    LATITUDE_KEYS = %w[latitude lat lat_dd lat_wgs84 dec_lat latitude_dd y].freeze
    LONGITUDE_KEYS = %w[longitude lng lon long lon_dd lng_dd long_dd lon_wgs84 dec_long dec_lon longitude_dd x].freeze

    MISSING_TOKENS = /\A(?:|na|n\/a|nd|bdl|n|null|none|nan|--+|-)\z/i

    def initialize(input, source: default_source, bulk: false)
      @input = input
      @source = source.to_s
      @bulk = bulk
    end

    def call
      created = 0
      updated = 0
      skipped = 0
      errors = []

      csv_content = read_input_content
      csv_body = strip_footer(strip_preamble(csv_content))
      col_sep = detect_separator(csv_body)

      rows = CSV.parse(csv_body, headers: true, col_sep: col_sep, liberal_parsing: true)
      rows.each_with_index.each_slice(500) do |batch|
        batch_counts =
          if @bulk
            import_batch_bulk(batch, errors)
          else
            import_batch_individual(batch, errors)
          end

        created += batch_counts[:created]
        updated += batch_counts[:updated]
        skipped += batch_counts[:skipped]
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

    def default_sample_media
      nil
    end

    def external_id_keys
      %w[external_id sample_id lab_id field_id id]
    end

    def rock_type_keys
      %w[rock_type rock_name lithology material sample_type]
    end

    def sample_media_keys
      %w[sample_media media material]
    end

    def latitude_keys
      LATITUDE_KEYS
    end

    def longitude_keys
      LONGITUDE_KEYS
    end

    def strip_preamble(content)
      content
    end

    def strip_footer(content)
      content
    end

    private

    def import_batch_individual(batch, errors)
      created = 0
      updated = 0
      skipped = 0

      ReferenceAssay.transaction do
        batch.each do |row, idx|
          attrs = parse_row_attributes(row, idx + 2, errors)
          if attrs.nil?
            skipped += 1
            next
          end

          assay = ReferenceAssay.find_or_initialize_by(source: attrs[:source], external_id: attrs[:external_id])
          was_new = assay.new_record?
          assay.assign_attributes(
            rock_type: attrs[:rock_type],
            sample_media: attrs[:sample_media],
            location: attrs[:location],
            oxides: attrs[:oxides],
            minor_oxides: attrs[:minor_oxides],
            trace_elements_ppm: attrs[:trace_elements_ppm],
            raw_metadata: attrs[:raw_metadata]
          )

          if assay.save
            if was_new
              created += 1
            else
              updated += 1
            end
          else
            skipped += 1
            errors << { row: idx + 2, reason: assay.errors.full_messages.to_sentence }
          end
        end
      end

      { created: created, updated: updated, skipped: skipped }
    end

    def import_batch_bulk(batch, errors)
      skipped = 0
      duplicate_in_batch = 0
      records_by_ext_id = {}
      now = Time.current

      batch.each do |row, idx|
        attrs = parse_row_attributes(row, idx + 2, errors)
        if attrs.nil?
          skipped += 1
          next
        end

        ext_id = attrs[:external_id]
        duplicate_in_batch += 1 if records_by_ext_id.key?(ext_id)
        records_by_ext_id[ext_id] = attrs.merge(created_at: now, updated_at: now)
      end

      return { created: 0, updated: 0, skipped: skipped } if records_by_ext_id.empty?

      ext_ids = records_by_ext_id.keys
      created = 0
      updated = 0

      ReferenceAssay.transaction do
        existing_map = ReferenceAssay.where(source: @source, external_id: ext_ids).pluck(:external_id).index_with(true)
        created = ext_ids.count { |eid| !existing_map.key?(eid) }
        updated = ext_ids.count { |eid| existing_map.key?(eid) } + duplicate_in_batch

        ReferenceAssay.upsert_all(
          records_by_ext_id.values,
          unique_by: :index_reference_assays_on_source_and_external_id
        )
      end

      { created: created, updated: updated, skipped: skipped }
    end

    def parse_row_attributes(row, row_num, errors)
      normalized_row = normalize_row_headers(row)

      lat = extract_coordinate(normalized_row, latitude_keys, -90.0..90.0)
      lng = extract_coordinate(normalized_row, longitude_keys, -180.0..180.0)
      if lat.nil? || lng.nil?
        errors << { row: row_num, reason: "Missing or invalid latitude/longitude" }
        return nil
      end

      raw_oxides = extract_oxides(normalized_row)
      if raw_oxides["SiO2"].nil? || !raw_oxides["SiO2"].positive? ||
          raw_oxides["Al2O3"].nil? || !raw_oxides["Al2O3"].positive?
        errors << { row: row_num, reason: "Missing valid numeric SiO2 or Al2O3" }
        return nil
      end

      normalized_oxides = CeramicOxides.normalize(raw_oxides)
      if normalized_oxides.nil?
        errors << { row: row_num, reason: "Oxide total must be positive" }
        return nil
      end

      rock_type = extract_rock_type(normalized_row)
      sample_media = extract_sample_media(normalized_row)
      trace_elements_ppm = extract_trace_elements_ppm(normalized_row)
      minor_oxides = extract_minor_oxides(normalized_row, trace_elements_ppm)
      external_id = extract_external_id(normalized_row, lat, lng, rock_type, normalized_oxides)

      {
        source: @source,
        external_id: external_id,
        rock_type: rock_type,
        sample_media: sample_media,
        location: Geolocatable.factory.point(lng, lat),
        oxides: normalized_oxides,
        minor_oxides: minor_oxides,
        trace_elements_ppm: trace_elements_ppm,
        raw_metadata: build_raw_metadata(row)
      }
    end

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
      first_line.count("\t") > first_line.count(",") ? "\t" : ","
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
        volatiles = VOLATILE_PATTERNS.filter_map do |pattern|
          matched_val = nil
          normalized_row.each do |key, raw_val|
            next unless key.match?(pattern)

            val = parse_float(raw_val, allow_negative: false)
            unless val.nil?
              matched_val = val
              break
            end
          end
          matched_val
        end
        direct["LOI"] = volatiles.sum if volatiles.any?
      end

      direct
    end

    def extract_trace_elements_ppm(normalized_row)
      CeramicOxides::TRACE_ELEMENT_KEYS.each_with_object({}) do |element, traces|
        ppm = extract_trace_element_ppm(normalized_row, element)
        traces[element] = ppm.round(4) if ppm&.positive?
      end
    end

    def extract_trace_element_ppm(normalized_row, element)
      el = element.downcase
      ppm_pattern = /\A#{el}(?:_(?:icp|icpms|icp_ms|icp_oes|oes|aes|xrf|ms|la|inaa|aas|tot|total))*_ppm\z/
      ppb_pattern = /\A#{el}(?:_(?:icp|icpms|icp_ms|icp_oes|oes|aes|xrf|ms|tot|total))*_ppb\z/
      pct_pattern = /\A#{el}(?:_(?:icp|icpms|icp_ms|icp_oes|oes|aes|xrf|ms|tot|total))*_(?:wt_?pct|wt|pct|percent)\z/
      bare_pattern = /\A#{el}\z/

      normalized_row.each do |key, raw_val|
        next unless key.match?(ppm_pattern)

        val = parse_float(raw_val, allow_negative: false)
        return val unless val.nil?
      end

      normalized_row.each do |key, raw_val|
        next unless key.match?(ppb_pattern)

        val = parse_float(raw_val, allow_negative: false)
        return val / 1000.0 unless val.nil?
      end

      normalized_row.each do |key, raw_val|
        next unless key.match?(pct_pattern)

        val = parse_float(raw_val, allow_negative: false)
        return val * 10_000.0 unless val.nil?
      end

      normalized_row.each do |key, raw_val|
        next unless key.match?(bare_pattern)

        val = parse_float(raw_val, allow_negative: false)
        next if val.nil?

        return val * 10_000.0 if element == "F" && val <= FLUORINE_BARE_WT_PCT_MAX

        return val
      end

      nil
    end

    def extract_minor_oxides(normalized_row, trace_elements_ppm)
      minor = {}

      # Pass 1: Direct minor oxide wt% columns
      normalized_row.each do |key, raw_val|
        val = parse_float(raw_val, allow_negative: false)
        next if val.nil? || !val.positive?

        MINOR_OXIDE_PATTERNS.each do |oxide, pattern|
          if key.match?(pattern)
            minor[oxide] ||= val.round(4)
            break
          end
        end
      end

      f_pct_pattern = /\Af(?:_(?:icp|icpms|icp_ms|icp_oes|oes|aes|xrf|ms|tot|total))*_(?:wt_?pct|wt|pct|percent)\z/
      normalized_row.each do |key, raw_val|
        next unless key.match?(f_pct_pattern)

        val = parse_float(raw_val, allow_negative: false)
        if val&.positive?
          minor["F"] ||= val.round(4)
          break
        end
      end

      if !minor.key?("F") && normalized_row.key?("f")
        val = parse_float(normalized_row["f"], allow_negative: false)
        minor["F"] = val.round(4) if val&.positive? && val <= FLUORINE_BARE_WT_PCT_MAX
      end

      # Pass 2: Convert elemental ppm/wt% via CeramicOxides::MINOR_ELEMENT_TO_OXIDE_FACTORS when >= 0.01 wt%
      CeramicOxides::MINOR_ELEMENT_TO_OXIDE_FACTORS.each do |element, spec|
        oxide = spec[:oxide]
        next if minor.key?(oxide)

        ppm = trace_elements_ppm[element]
        next if ppm.nil? || !ppm.positive?

        oxide_wt_pct = (ppm / 10_000.0) * spec[:factor]
        minor[oxide] = oxide_wt_pct.round(4) if oxide_wt_pct >= MINOR_OXIDE_MIN_WT_PCT
      end

      minor
    end

    def extract_sample_media(normalized_row)
      sample_media_keys.each do |key|
        val = normalized_row[key]&.to_s&.strip
        return val.downcase if val && !val.empty? && !val.match?(MISSING_TOKENS)
      end
      default_sample_media
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
