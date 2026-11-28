# frozen_string_literal: true

require "csv"

module Lab
  class VerifiedAssayImporter
    Result = Struct.new(
      :assay_result,
      :reference_assay,
      :comparison,
      :errors,
      keyword_init: true
    ) do
      def success?
        Array(errors).empty? && assay_result.present?
      end
    end

    VALID_SOURCE_TYPES = %w[verified_lab_xrf verified_lab_icpms].freeze
    VERIFIED_CONFIDENCE_SCORE = 0.98
    FIRED_OXIDES = (CeramicOxides::KEYS - [ "LOI" ]).freeze

    OXIDE_PATTERNS = {
      "SiO2"   => /\Asio2(?:_(?:wt_?pct|wt|pct|percent|fus|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "Al2O3"  => /\Aal2o3(?:_(?:wt_?pct|wt|pct|percent|fus|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "Fe2O3T" => /\Afe2o3(?:_?t|_?tot(?:al)?)(?:_(?:wt_?pct|wt|pct|percent|fus|xrf|icp|icpms|oes|aes))*\z/,
      "Fe2O3"  => /\Afe2o3(?:_(?:wt_?pct|wt|pct|percent|fus|xrf|icp|icpms|oes|aes))*\z/,
      "FeO"    => /\Afeo(?:_?t|_?tot(?:al)?)?(?:_(?:wt_?pct|wt|pct|percent|fus|xrf|icp|icpms|oes|aes))*\z/,
      "CaO"    => /\Acao(?:_(?:wt_?pct|wt|pct|percent|fus|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "MgO"    => /\Amgo(?:_(?:wt_?pct|wt|pct|percent|fus|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "Na2O"   => /\Ana2o(?:_(?:wt_?pct|wt|pct|percent|fus|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "K2O"    => /\Ak2o(?:_(?:wt_?pct|wt|pct|percent|fus|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "TiO2"   => /\Atio2(?:_(?:wt_?pct|wt|pct|percent|fus|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "P2O5"   => /\Ap2o5(?:_(?:wt_?pct|wt|pct|percent|fus|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "MnO"    => /\Amno(?:_(?:wt_?pct|wt|pct|percent|fus|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "LOI"    => /\A(?:loi|loss_on_ignition)(?:_(?:loi|wt_?pct|wt|pct|percent|\d+c?))*\z/
    }.freeze

    VOLATILE_KEYS = %w[h2o_plus h2o_minus h2o_tot h2o co2].freeze
    MISSING_TOKENS = /\A(?:|na|n\/a|nd|bdl|n|null|none|nan|--+|-)\z/i
    METADATA_ROW_PATTERN = /\A(?:unit|units|unit\s+symbol|detection\s+limit|dl|mdl|method|analysis\s+method|report|client|date|%|wt%)\b/i
    VALUE_HEADER_PATTERN = /(?:wt|pct|percent|result|value|conc|amount|analysis)/i
    SKIP_VALUE_HEADER_PATTERN = /(?:limit|dl|mdl|unit|method|symbol)/i

    def self.call(
      user_sample:,
      source_type: :verified_lab_xrf,
      oxides: nil,
      csv_file: nil,
      lab_name: nil,
      lab_report_ref: nil,
      promote_to_reference: false,
      coordinate_privacy: "exact",
      promoted_by_user: nil
    )
      new(
        user_sample: user_sample,
        source_type: source_type,
        oxides: oxides,
        csv_file: csv_file,
        lab_name: lab_name,
        lab_report_ref: lab_report_ref,
        promote_to_reference: promote_to_reference,
        coordinate_privacy: coordinate_privacy,
        promoted_by_user: promoted_by_user
      ).call
    end

    def self.compare(heuristic_assay, lab_assay)
      return nil if heuristic_assay.nil? || lab_assay.nil?

      h_oxides = heuristic_assay.oxides.is_a?(Hash) ? heuristic_assay.oxides.transform_keys(&:to_s) : {}
      l_oxides = lab_assay.oxides.is_a?(Hash) ? lab_assay.oxides.transform_keys(&:to_s) : {}
      return nil if h_oxides.empty? || l_oxides.empty?

      h_ranges = heuristic_assay.oxide_ranges.is_a?(Hash) ? heuristic_assay.oxide_ranges.transform_keys(&:to_s) : {}

      per_oxide = []
      raw_deltas = []
      in_range_count = 0
      in_range_total = 0

      CeramicOxides::KEYS.each do |oxide|
        h_val = h_oxides[oxide].to_f
        l_val = l_oxides[oxide].to_f
        raw_delta = l_val - h_val
        raw_deltas << raw_delta

        range_entry = h_ranges[oxide]
        range_min = nil
        range_max = nil
        within_range = nil

        if range_entry.is_a?(Hash) && !range_entry["min"].nil? && !range_entry["max"].nil?
          range_min = range_entry["min"].to_f.round(2)
          range_max = range_entry["max"].to_f.round(2)
          within_range = l_val >= (range_entry["min"].to_f - 0.001) && l_val <= (range_entry["max"].to_f + 0.001)
          in_range_total += 1
          in_range_count += 1 if within_range
        end

        per_oxide << {
          oxide: oxide,
          heuristic: h_val.round(2),
          lab: l_val.round(2),
          delta: raw_delta.round(2),
          abs_error: raw_delta.abs.round(2),
          within_range: within_range,
          min: range_min,
          max: range_max
        }
      end

      count = raw_deltas.size.to_f
      mae = (raw_deltas.sum(&:abs) / count).round(2)
      rmse = Math.sqrt(raw_deltas.sum { |d| d * d } / count).round(2)

      {
        per_oxide: per_oxide,
        mae: mae,
        rmse: rmse,
        in_range_count: in_range_count,
        in_range_total: in_range_total,
        si_al_heuristic: extract_si_al_ratio(heuristic_assay, h_oxides),
        si_al_lab: extract_si_al_ratio(lab_assay, l_oxides)
      }
    end

    def self.extract_si_al_ratio(assay, oxides)
      stored = assay.umf_formula.is_a?(Hash) ? (assay.umf_formula["si_al_ratio"] || assay.umf_formula[:si_al_ratio]) : nil
      ratio = stored.nil? ? Chemistry::UmfCalculator.call(oxides)["si_al_ratio"] : stored
      ratio.nil? ? nil : ratio.to_f.round(2)
    end
    private_class_method :extract_si_al_ratio

    def initialize(
      user_sample:,
      source_type: :verified_lab_xrf,
      oxides: nil,
      csv_file: nil,
      lab_name: nil,
      lab_report_ref: nil,
      promote_to_reference: false,
      coordinate_privacy: "exact",
      promoted_by_user: nil
    )
      @user_sample = user_sample
      @source_type = (source_type.presence || :verified_lab_xrf).to_s
      @oxides = oxides
      @csv_file = csv_file
      @lab_name = lab_name.to_s.strip.presence
      @lab_report_ref = lab_report_ref.to_s.strip.presence
      @promote_to_reference = ActiveModel::Type::Boolean.new.cast(promote_to_reference) || false
      @coordinate_privacy = coordinate_privacy.to_s.presence || "exact"
      @promoted_by_user = promoted_by_user
      @errors = []
      @feo_converted = false
      @input_mode = nil
    end

    def call
      validate_inputs!
      return failure_result if @errors.any?

      raw_oxides = extract_input_oxides
      return failure_result if @errors.any?

      validate_oxides!(raw_oxides)
      return failure_result if @errors.any?

      normalized = Exporters::GlazecalcMaterialSerializer.normalize_oxides(raw_oxides)
      umf = Chemistry::UmfCalculator.call(normalized)
      heuristic_assay = @user_sample.latest_heuristic_assay_result

      assay_result = nil
      reference_assay = nil
      comparison = nil

      AssayResult.transaction do
        assay_result = @user_sample.assay_results.build(
          source_type: @source_type,
          oxides: normalized,
          oxide_ranges: {},
          umf_formula: umf,
          confidence_score: VERIFIED_CONFIDENCE_SCORE,
          lab_name: @lab_name,
          lab_report_ref: @lab_report_ref,
          promoted_to_reference: false,
          reasoning_log: []
        )

        comparison = self.class.compare(heuristic_assay, assay_result)
        reasoning_entries = build_reasoning_log(comparison)

        if @promote_to_reference
          if @user_sample.latitude.present? && @user_sample.longitude.present?
            reference_assay = upsert_community_reference_assay!(normalized)
            assay_result.reference_assay = reference_assay
            assay_result.promoted_to_reference = true
            privacy_note = @coordinate_privacy == "fuzzed_2km" ? " (fuzzed ~2 km)" : ""
            reasoning_entries << "Promoted to Regional Spatial Atlas#{privacy_note} (ReferenceAssay ##{reference_assay.id}, source: #{reference_assay.source}) as 2.5x weighted calibration prior."
          else
            reasoning_entries << "Skipped Regional Spatial Atlas promotion: sample has no GPS coordinates."
          end
        end

        assay_result.reasoning_log = reasoning_entries
        assay_result.save!

        sync_sample_community_reference_assays!(assay_result, reference_assay)
      end

      Result.new(
        assay_result: assay_result,
        reference_assay: reference_assay,
        comparison: comparison,
        errors: []
      )
    rescue ActiveRecord::RecordInvalid => e
      @errors << e.record.errors.full_messages.to_sentence
      failure_result
    rescue ArgumentError => e
      @errors << e.message
      failure_result
    end

    private

    def failure_result
      Result.new(
        assay_result: nil,
        reference_assay: nil,
        comparison: nil,
        errors: @errors
      )
    end

    def validate_inputs!
      if @user_sample.nil? || !@user_sample.persisted?
        @errors << "User sample must be saved before logging a verified lab assay."
      end

      unless VALID_SOURCE_TYPES.include?(@source_type)
        @errors << "Source type must be verified_lab_xrf or verified_lab_icpms."
      end

      if @promote_to_reference && !ReferenceAssay::COORDINATE_PRIVACY_MODES.include?(@coordinate_privacy)
        @errors << "Coordinate privacy must be exact or fuzzed_2km."
      end
    end

    def extract_input_oxides
      csv_content = read_csv_content
      if csv_content.present?
        @input_mode = :csv
        parse_csv_oxides(csv_content)
      elsif manual_oxides_present?
        @input_mode = :manual
        parse_manual_oxides(@oxides)
      else
        @errors << "Provide a lab report CSV file or enter oxide weight percentages."
        {}
      end
    end

    def read_csv_content
      return nil if @csv_file.nil?

      raw = if @csv_file.respond_to?(:read)
        @csv_file.rewind if @csv_file.respond_to?(:rewind)
        @csv_file.read
      elsif @csv_file.is_a?(String)
        str = @csv_file
        if !str.include?("\n") && !str.include?("\r") && !str.include?(",") && !str.include?("\t") && File.file?(str)
          File.read(str, encoding: "bom|utf-8")
        else
          str
        end
      else
        @csv_file.to_s
      end

      cleaned = raw.to_s.encode("UTF-8", invalid: :replace, undef: :replace, replace: "").sub(/\A\uFEFF/, "")
      cleaned.strip.empty? ? nil : cleaned
    rescue Errno::ENOENT, IOError => e
      @errors << "Could not read CSV file: #{e.message}"
      nil
    end

    def manual_oxides_present?
      return false unless @oxides.respond_to?(:to_h) || @oxides.respond_to?(:to_unsafe_h)

      hash = @oxides.respond_to?(:to_unsafe_h) ? @oxides.to_unsafe_h : @oxides.to_h
      hash.values.any? { |v| v.to_s.strip.present? }
    end

    def parse_manual_oxides(raw_hash)
      source = raw_hash.respond_to?(:to_unsafe_h) ? raw_hash.to_unsafe_h : raw_hash.to_h
      canonical_map = {}

      source.each do |raw_key, raw_val|
        str = raw_val.to_s.strip
        next if str.empty?

        key = canonicalize_header(raw_key)
        next if key.nil? || key.empty?

        if str.match?(MISSING_TOKENS) || str.start_with?("<", ">")
          canonical_map[key] = 0.0
          next
        end

        num = parse_strict_non_negative_float(str)
        if num.nil?
          @errors << "#{raw_key} must be a non-negative number."
        else
          canonical_map[key] = num
        end
      end

      return {} if @errors.any?

      resolve_oxide_map(canonical_map)
    end

    def parse_csv_oxides(content)
      col_sep = detect_separator(content)
      rows = CSV.parse(content, col_sep: col_sep, liberal_parsing: true)
      non_empty_rows = rows.reject { |row| row.nil? || row.all? { |cell| cell.to_s.strip.empty? } }

      if non_empty_rows.empty?
        @errors << "Uploaded CSV file is empty."
        return {}
      end

      oxides = parse_horizontal_csv(non_empty_rows)
      oxides = parse_vertical_csv(non_empty_rows) if oxides.empty?

      if oxides.empty?
        @errors << "Could not parse recognized ceramic oxide columns from the uploaded CSV."
      end

      oxides
    rescue CSV::MalformedCSVError => e
      @errors << "Uploaded CSV could not be parsed: #{e.message}"
      {}
    end

    def detect_separator(content)
      candidate_lines = content.lines.map(&:strip).reject(&:empty?)
      delimited_line = candidate_lines.find { |line| line.match?(/sio2|al2o3|fe2o3|feo|oxide|analyte/i) && line.match?(/[\t,;]/) } ||
        candidate_lines.find { |line| line.match?(/[\t,;]/) } || ""

      counts = {
        "," => delimited_line.count(","),
        "\t" => delimited_line.count("\t"),
        ";" => delimited_line.count(";")
      }
      best_sep, best_count = counts.max_by { |_, count| count }
      best_count.positive? ? best_sep : ","
    end

    def parse_horizontal_csv(rows)
      header_idx = rows.index do |row|
        matched = row.filter_map { |cell| match_oxide_key(canonicalize_header(cell)) }.uniq
        matched.size >= 2
      end
      return {} if header_idx.nil?

      headers = rows[header_idx].map { |cell| canonicalize_header(cell) }
      data_rows = rows[(header_idx + 1)..] || []

      data_rows.each do |row|
        first_cell = row.first.to_s.strip
        next if first_cell.match?(METADATA_ROW_PATTERN)

        row_map = {}
        headers.each_with_index do |key, idx|
          next if key.nil? || key.empty?
          next if idx >= row.length

          if !row_map.key?(key) || row_map[key].to_s.strip.empty?
            row_map[key] = row[idx]
          end
        end

        extracted = resolve_oxide_map(row_map)
        fired_sum = FIRED_OXIDES.sum { |ox| extracted[ox].to_f }
        return extracted if fired_sum.positive?
      end

      {}
    end

    def parse_vertical_csv(rows)
      value_col_idx = detect_vertical_value_column(rows)
      kv_map = {}

      rows.each do |row|
        next if row.length < 2

        label_key = canonicalize_header(row[0])
        next if label_key.nil? || label_key.empty?
        next unless recognized_oxide_or_volatile?(label_key)
        next if kv_map.key?(label_key)

        raw_val = extract_vertical_row_value(row, value_col_idx)
        kv_map[label_key] = raw_val unless raw_val.nil?
      end

      return {} if kv_map.empty?

      resolve_oxide_map(kv_map)
    end

    def detect_vertical_value_column(rows)
      rows.each do |row|
        next if row.length < 2

        first = row[0].to_s.strip
        next unless first.match?(/\A(?:oxide|analyte|component|constituent|element|parameter)/i)

        row[1..].each_with_index do |cell, offset|
          text = cell.to_s.strip
          next if text.empty? || text.match?(SKIP_VALUE_HEADER_PATTERN)
          return offset + 1 if text.match?(VALUE_HEADER_PATTERN)
        end
      end

      nil
    end

    def extract_vertical_row_value(row, preferred_idx)
      if preferred_idx
        return preferred_idx < row.length ? row[preferred_idx] : nil
      end

      row[1..].each do |cell|
        return cell if parse_csv_float(cell)
      end

      nil
    end

    def resolve_oxide_map(normalized_map)
      direct = {}
      fe2o3_total = nil
      fe2o3_ferric = nil
      feo_val = nil

      normalized_map.each do |key, raw_val|
        val = raw_val.is_a?(Numeric) ? raw_val.to_f : parse_csv_float(raw_val)
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

      if !fe2o3_total.nil?
        direct["Fe2O3"] = fe2o3_total
      elsif !fe2o3_ferric.nil? || !feo_val.nil?
        @feo_converted = true if feo_val.to_f.positive?
        direct["Fe2O3"] = (fe2o3_ferric || 0.0) + ((feo_val || 0.0) * CeramicOxides::FEO_TO_FE2O3_FACTOR)
      end

      # Fallback to elemental wt% or ppm columns for any missing oxide
      CeramicOxides::ELEMENT_TO_OXIDE_FACTORS.each do |element, spec|
        oxide = spec[:oxide]
        next unless direct[oxide].nil?

        el_wt_pct = extract_element_wt_pct(normalized_map, element)
        next if el_wt_pct.nil?

        direct[oxide] = el_wt_pct * spec[:factor]
      end

      # Fallback LOI from H2O+/H2O-/CO2 volatiles when LOI is omitted
      if direct["LOI"].nil?
        volatiles = VOLATILE_KEYS.filter_map do |vk|
          raw = normalized_map[vk]
          raw.is_a?(Numeric) ? raw.to_f : parse_csv_float(raw)
        end
        direct["LOI"] = volatiles.sum if volatiles.any?
      end

      direct
    end

    def extract_element_wt_pct(normalized_map, element)
      el = element.downcase
      pct_pattern = /\A#{el}(?:_(?:icp|icpms|oes|aes|xrf|ms|tot|total))*_(?:wt_?pct|wt|pct|percent)\z/
      ppm_pattern = /\A#{el}(?:_(?:icp|icpms|oes|aes|xrf|ms|tot|total))*_ppm\z/

      normalized_map.each do |key, raw_val|
        next unless key.match?(pct_pattern)

        val = raw_val.is_a?(Numeric) ? raw_val.to_f : parse_csv_float(raw_val)
        return val unless val.nil?
      end

      normalized_map.each do |key, raw_val|
        next unless key.match?(ppm_pattern)

        val = raw_val.is_a?(Numeric) ? raw_val.to_f : parse_csv_float(raw_val)
        return val / 10_000.0 unless val.nil?
      end

      nil
    end

    def validate_oxides!(raw_oxides)
      if raw_oxides.empty?
        @errors << "At least one positive fired oxide (such as SiO2 and Al2O3) is required."
        return
      end

      fired_total = FIRED_OXIDES.sum { |ox| raw_oxides[ox].to_f }
      unless fired_total.positive?
        @errors << "Fired oxides must sum to a positive weight percentage (enter SiO2, Al2O3, or other ceramic oxides)."
      end
    end

    def canonicalize_header(header)
      return nil if header.nil?

      header
        .to_s
        .sub(/\A\uFEFF/, "")
        .strip
        .gsub("*", "_t")
        .gsub("+", "_plus")
        .gsub(/h2o\s*-/i, "h2o_minus")
        .gsub("%", "_pct")
        .downcase
        .gsub(/[^a-z0-9]+/, "_")
        .gsub(/\A_+|_+\z/, "")
    end

    def match_oxide_key(canonical_key)
      return nil if canonical_key.nil? || canonical_key.empty?

      OXIDE_PATTERNS.each do |oxide, pattern|
        return oxide if canonical_key.match?(pattern)
      end
      nil
    end

    def recognized_oxide_or_volatile?(canonical_key)
      match_oxide_key(canonical_key).present? || VOLATILE_KEYS.include?(canonical_key)
    end

    def parse_csv_float(raw_val)
      return nil if raw_val.nil?

      str = raw_val.to_s.strip.sub(/%\z/, "").strip
      return nil if str.empty? || str.match?(MISSING_TOKENS)
      return nil if str.start_with?("<", ">")

      val = Float(str)
      return nil if val.nan? || val.infinite? || val.negative?

      val
    rescue ArgumentError, TypeError
      nil
    end

    def parse_strict_non_negative_float(str)
      cleaned = str.sub(/%\z/, "").strip
      val = Float(cleaned)
      return nil if val.nan? || val.infinite? || val.negative?

      val
    rescue ArgumentError, TypeError
      nil
    end

    def build_reasoning_log(comparison)
      entries = []
      method_label = @source_type == "verified_lab_icpms" ? "Verified Lab ICP-MS" : "Verified Lab XRF"
      qualifier_parts = [ @lab_name, @lab_report_ref ].compact
      qualifier = qualifier_parts.any? ? " (#{qualifier_parts.join(' · ')})" : ""
      input_note = @input_mode == :csv ? "uploaded via CSV" : "entered manually"

      entries << "#{method_label} #{input_note}#{qualifier} — normalized to 100.00% wt basis."

      if @feo_converted
        entries << "Converted ferrous iron (FeO/FeOT) to Fe2O3 using stoichiometric factor #{CeramicOxides::FEO_TO_FE2O3_FACTOR}."
      end

      if comparison.present?
        range_note = if comparison[:in_range_total].positive?
          " (#{comparison[:in_range_count]}/#{comparison[:in_range_total]} oxides within predicted range)"
        else
          ""
        end
        entries << "Residual calibration vs spatial heuristic: MAE #{format('%.2f', comparison[:mae])} wt%, RMSE #{format('%.2f', comparison[:rmse])} wt%#{range_note}."
      end

      entries
    end

    def upsert_community_reference_assay!(normalized_oxides)
      ref_source = @source_type == "verified_lab_icpms" ? "community_verified_icpms" : "community_verified_xrf"
      external_id = "sample-#{@user_sample.id}-#{@source_type}"

      ref_assay = ReferenceAssay.find_or_initialize_by(source: ref_source, external_id: external_id)
      ref_assay.assign_attributes(
        rock_type: infer_rock_type(@user_sample),
        coordinate_privacy: @coordinate_privacy,
        promoted_by_user: @promoted_by_user,
        oxides: normalized_oxides,
        raw_metadata: {
          "sample_title" => @user_sample.title,
          "lab_name" => @lab_name,
          "lab_report_ref" => @lab_report_ref,
          "geologic_unit" => @user_sample.geologic_unit&.name,
          "coordinate_privacy" => @coordinate_privacy
        }.compact
      )
      if @coordinate_privacy == "fuzzed_2km"
        fuzzed_lat, fuzzed_lng = ReferenceAssay.fuzz_coordinates(
          @user_sample.latitude,
          @user_sample.longitude,
          seed_key: "sample-#{@user_sample.id}"
        )
        ref_assay.latitude = fuzzed_lat
        ref_assay.longitude = fuzzed_lng
      else
        ref_assay.location = @user_sample.location
      end
      ref_assay.save!
      ref_assay
    end

    def sync_sample_community_reference_assays!(assay_result, reference_assay)
      if reference_assay.present?
        @user_sample.assay_results
          .where(reference_assay_id: reference_assay.id)
          .where.not(id: assay_result.id)
          .update_all(reference_assay_id: nil, promoted_to_reference: false)

        other_ref_ids = @user_sample.assay_results
          .where.not(reference_assay_id: [ nil, reference_assay.id ])
          .distinct
          .pluck(:reference_assay_id)

        if other_ref_ids.any?
          ReferenceAssay
            .where(id: other_ref_ids)
            .where("source LIKE 'community_verified_%'")
            .find_each do |sibling_ref|
              merged_meta = (sibling_ref.raw_metadata || {}).merge("coordinate_privacy" => reference_assay.coordinate_privacy)
              sibling_ref.update!(
                coordinate_privacy: reference_assay.coordinate_privacy,
                location: reference_assay.location,
                raw_metadata: merged_meta
              )
            end
        end
      elsif !@promote_to_reference
        prior_ref_ids = @user_sample.assay_results
          .where.not(reference_assay_id: nil)
          .distinct
          .pluck(:reference_assay_id)

        @user_sample.assay_results
          .where("promoted_to_reference = TRUE OR reference_assay_id IS NOT NULL")
          .update_all(promoted_to_reference: false, reference_assay_id: nil, updated_at: Time.current)

        if prior_ref_ids.any?
          ReferenceAssay
            .where(id: prior_ref_ids)
            .where("source LIKE 'community_verified_%'")
            .find_each do |prior_ref|
              prior_ref.destroy! if AssayResult.where(reference_assay_id: prior_ref.id).none?
            end
        end
      end
    end

    def infer_rock_type(sample)
      category = sample.material_category.to_s
      terms = Array(sample.geologic_unit&.lithology_terms)

      if terms.any? && defined?(Inference::BaselineEstimatorService)
        category_types = Inference::BaselineEstimatorService::CATEGORY_ROCK_TYPES.fetch(category, [])
        matched_types = []
        terms.each do |term|
          Inference::BaselineEstimatorService::LITHOLOGY_KEYWORD_RULES.each do |pattern, rock_types|
            matched_types.concat(rock_types) if term.to_s.match?(pattern)
          end
        end
        matched_types.uniq!

        preferred = category_types.any? ? (matched_types & category_types) : matched_types
        return preferred.first if preferred.any?
        return matched_types.first if matched_types.any? && category == "crushed_rock"
      end

      case category
      when "wild_clay"
        "clay"
      when "wood_ash"
        "wood_ash"
      when "crushed_rock"
        terms.first.presence || "crushed_rock"
      else
        terms.first.presence || "other"
      end
    end
  end
end
