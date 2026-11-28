# frozen_string_literal: true

require "csv"

module Lab
  # Parses handheld pXRF CSV/TSV exports (Bruker S1 TITAN/CTX, Olympus Vanta,
  # Thermo Niton) containing elemental % or ppm readings (plus optional oxide
  # mode), integrates studio kiln weight-loss LOI measurements, converts major
  # and significant minor ceramic elements to oxides, preserves full trace
  # elements in ppm, computes full-oxide UMF, screens hazards/pathfinders, and
  # persists a verified pXRF AssayResult.
  class PxrfCsvImporter
    Result = Struct.new(
      :assay_result,
      :reference_assay,
      :comparison,
      :hazard_report,
      :measured_loi_pct,
      :errors,
      keyword_init: true
    ) do
      def success?
        Array(errors).empty? && assay_result.present?
      end
    end

    CONFIDENCE_WITH_LOI = 0.90
    CONFIDENCE_WITHOUT_LOI = 0.82
    SIGNIFICANT_MINOR_PPM = 500.0
    SIGNIFICANT_MINOR_OXIDE_PCT = 0.05

    MAJOR_ELEMENTS = CeramicOxides::ELEMENT_TO_OXIDE_FACTORS.keys.freeze
    TRACE_ELEMENTS = CeramicOxides::TRACE_ELEMENT_KEYS.freeze
    ALL_ELEMENTS = (MAJOR_ELEMENTS + TRACE_ELEMENTS).uniq.freeze
    ELEMENT_LOOKUP = ALL_ELEMENTS.each_with_object({}) { |el, acc| acc[el.downcase] = el }.freeze

    FIRED_MAJOR_OXIDES = (CeramicOxides::KEYS - [ "LOI" ]).freeze
    ALL_OXIDE_KEYS = ((CeramicOxides::KEYS + CeramicOxides::MINOR_KEYS) - [ "F" ]).uniq.freeze
    OXIDE_LOOKUP = ALL_OXIDE_KEYS.each_with_object({}) { |ox, acc| acc[ox.downcase] = ox }.merge(
      "fe2o3t" => "Fe2O3T",
      "fe2o3tot" => "Fe2O3T",
      "fe2o3total" => "Fe2O3T",
      "feot" => "FeO",
      "feo" => "FeO"
    ).freeze

    ERROR_HEADER_PATTERN = /(?:(?:\A|[^a-z])(?:err(?:or)?\d*s?|std|sd|unc(?:ertainty)?|sigma|2s|1s|lod|dl|mdl)(?:\z|[^a-z])|\+\/-|±)/i
    SKIP_HEADER_PATTERN = /\A(?:le|light[\s_-]*elements?|bal(?:ance)?|total|sum|duration|time|date|mode|method|application|instrument|operator|type|pass|fail|notes?|comments?|calibration)\z/i
    SAMPLE_ID_HEADER_PATTERN = /\A(?:sample(?:[\s_-]*(?:id|name|no|num|#))?|reading(?:[\s_-]*(?:id|no|num|#))?|name|id)\z/i
    UNITS_HEADER_PATTERN = /\Aunits?\z/i

    MISSING_TOKENS = /\A(?:|na|n\/a|nd|bdl|lod|<lod|<dl|n|null|none|nan|--+|-)\z/i
    UNIT_ROW_CELL_PATTERN = /\A(?:%|wt\s*%|wt\s*pct|pct|percent|ppm|ppb|mg\/kg|ug\/g|µg\/g|unit|units)\z/i
    METADATA_FIRST_CELL_PATTERN = /\A(?:unit|units|detection\s+limit|dl|mdl|lod|method|instrument|calibration|report|client|date)\b/i

    def self.call(
      user_sample:,
      csv_file:,
      dry_weight_g: nil,
      fired_weight_g: nil,
      measured_loi_pct: nil,
      lab_name: nil,
      lab_report_ref: nil,
      promote_to_reference: false,
      coordinate_privacy: "exact",
      promoted_by_user: nil
    )
      new(
        user_sample: user_sample,
        csv_file: csv_file,
        dry_weight_g: dry_weight_g,
        fired_weight_g: fired_weight_g,
        measured_loi_pct: measured_loi_pct,
        lab_name: lab_name,
        lab_report_ref: lab_report_ref,
        promote_to_reference: promote_to_reference,
        coordinate_privacy: coordinate_privacy,
        promoted_by_user: promoted_by_user
      ).call
    end

    def self.calculate_kiln_loi(dry_weight_g:, fired_weight_g:)
      dry = Float(dry_weight_g)
      fired = Float(fired_weight_g)
      raise ArgumentError, "Dry weight must be a positive number." unless dry.finite? && dry.positive?
      raise ArgumentError, "Fired weight must be a non-negative number." unless fired.finite? && fired >= 0.0
      raise ArgumentError, "Fired weight cannot exceed dry weight." if fired > dry

      (((dry - fired) / dry) * 100.0).clamp(0.0, 99.9).round(2)
    rescue ArgumentError, TypeError => e
      raise ArgumentError, e.message
    end

    def initialize(
      user_sample:,
      csv_file:,
      dry_weight_g: nil,
      fired_weight_g: nil,
      measured_loi_pct: nil,
      lab_name: nil,
      lab_report_ref: nil,
      promote_to_reference: false,
      coordinate_privacy: "exact",
      promoted_by_user: nil
    )
      @user_sample = user_sample
      @csv_file = csv_file
      @dry_weight_g_raw = dry_weight_g
      @fired_weight_g_raw = fired_weight_g
      @measured_loi_pct_raw = measured_loi_pct
      @lab_name = lab_name.to_s.strip.presence
      @lab_report_ref = lab_report_ref.to_s.strip.presence
      @promote_to_reference = ActiveModel::Type::Boolean.new.cast(promote_to_reference) || false
      @coordinate_privacy = coordinate_privacy.to_s.presence || "exact"
      @promoted_by_user = promoted_by_user

      @errors = []
      @loi_measured = false
      @loi_source = nil
      @measured_loi_pct = nil
      @dry_weight_g = nil
      @fired_weight_g = nil
      @detected_sample_id = nil
    end

    def call
      validate_inputs!
      return failure_result if @errors.any?

      loi_from_input = resolve_input_loi!
      return failure_result if @errors.any?

      csv_content = read_csv_content
      return failure_result if @errors.any?

      if csv_content.blank?
        @errors << "Provide a handheld pXRF CSV or TSV file (Bruker, Olympus Vanta, or Thermo Niton)."
        return failure_result
      end

      parsed = parse_pxrf_csv(csv_content)
      return failure_result if @errors.any?

      major_oxides, minor_oxides, trace_ppm, csv_loi = convert_parsed_chemistry(parsed)
      fired_major_sum = FIRED_MAJOR_OXIDES.sum { |ox| major_oxides[ox].to_f }

      unless fired_major_sum.positive?
        @errors << "Could not extract positive major ceramic elements (Si, Al, Fe, Ca, K, etc.) from the pXRF CSV."
        return failure_result
      end

      effective_loi = if @loi_measured
        loi_from_input
      elsif !csv_loi.nil? && csv_loi >= 0.0
        @loi_measured = true
        @loi_source = :csv
        @measured_loi_pct = csv_loi.clamp(0.0, 99.9).round(2)
      else
        0.0
      end

      # Preserve studio-measured kiln LOI while normalizing measured major fired oxides to (100 - LOI)%.
      normalized_input = major_oxides.dup
      if @loi_measured && effective_loi.positive?
        target_fired = [ 100.0 - effective_loi, 0.1 ].max
        scale = target_fired / fired_major_sum
        FIRED_MAJOR_OXIDES.each do |ox|
          normalized_input[ox] = normalized_input[ox].to_f * scale
        end
        normalized_input["LOI"] = effective_loi
      else
        normalized_input["LOI"] = effective_loi
      end

      normalized_oxides = Exporters::GlazecalcMaterialSerializer.normalize_oxides(normalized_input)
      umf = Chemistry::UmfCalculator.call(normalized_oxides, minor_oxides: minor_oxides)
      heuristic_assay = @user_sample.latest_heuristic_assay_result
      confidence = @loi_measured ? CONFIDENCE_WITH_LOI : CONFIDENCE_WITHOUT_LOI

      assay_result = nil
      reference_assay = nil
      comparison = nil
      hazard_report = nil

      AssayResult.transaction do
        assay_result = @user_sample.assay_results.build(
          source_type: :verified_lab_xrf,
          analysis_method: "pxrf",
          oxides: normalized_oxides,
          minor_oxides: minor_oxides,
          trace_elements_ppm: trace_ppm,
          oxide_ranges: {},
          umf_formula: umf,
          confidence_score: confidence,
          lab_name: @lab_name || "Handheld pXRF",
          lab_report_ref: @lab_report_ref || @detected_sample_id,
          promoted_to_reference: false,
          reasoning_log: []
        )

        comparison = Lab::VerifiedAssayImporter.compare(heuristic_assay, assay_result)
        hazard_report = Chemistry::HazardScreenerService.call(
          assay_result: assay_result,
          user_sample: @user_sample
        )
        reasoning_entries = build_reasoning_log(
          comparison: comparison,
          minor_oxides: minor_oxides,
          trace_ppm: trace_ppm,
          hazard_report: hazard_report,
          effective_loi: effective_loi
        )

        if @promote_to_reference
          if @user_sample.latitude.present? && @user_sample.longitude.present?
            reference_assay = upsert_community_reference_assay!(normalized_oxides, minor_oxides, trace_ppm)
            assay_result.reference_assay = reference_assay
            assay_result.promoted_to_reference = true
            privacy_note = @coordinate_privacy == "fuzzed_2km" ? " (fuzzed ~2 km)" : ""
            reasoning_entries << "Promoted pXRF assay to Regional Spatial Atlas#{privacy_note} (ReferenceAssay ##{reference_assay.id}, source: #{reference_assay.source})."
          else
            reasoning_entries << "Skipped Regional Spatial Atlas promotion: sample has no GPS coordinates."
          end
        end

        assay_result.reasoning_log = reasoning_entries
        assay_result.save!

        if reference_assay.present?
          @user_sample.assay_results
            .where(reference_assay_id: reference_assay.id)
            .where.not(id: assay_result.id)
            .update_all(reference_assay_id: nil, promoted_to_reference: false)
        end
      end

      Result.new(
        assay_result: assay_result,
        reference_assay: reference_assay,
        comparison: comparison,
        hazard_report: hazard_report,
        measured_loi_pct: @measured_loi_pct,
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
        hazard_report: nil,
        measured_loi_pct: @measured_loi_pct,
        errors: @errors
      )
    end

    def validate_inputs!
      if @user_sample.nil? || !@user_sample.persisted?
        @errors << "User sample must be saved before logging a handheld pXRF assay."
      end

      if @promote_to_reference && !ReferenceAssay::COORDINATE_PRIVACY_MODES.include?(@coordinate_privacy)
        @errors << "Coordinate privacy must be exact or fuzzed_2km."
      end
    end

    def resolve_input_loi!
      dry_str = @dry_weight_g_raw.to_s.strip
      fired_str = @fired_weight_g_raw.to_s.strip
      direct_str = @measured_loi_pct_raw.to_s.strip

      if dry_str.present? || fired_str.present?
        if dry_str.blank? || fired_str.blank?
          @errors << "Provide both dry weight (g) and fired weight (g) to calculate studio kiln LOI."
          return nil
        end

        dry = parse_strict_float(dry_str)
        fired = parse_strict_float(fired_str)
        if dry.nil? || !dry.positive?
          @errors << "Dry weight (g) must be a positive number."
          return nil
        end
        if fired.nil? || fired.negative?
          @errors << "Fired weight (g) must be a non-negative number."
          return nil
        end
        if fired > dry
          @errors << "Fired weight cannot exceed dry weight for kiln LOI calculation."
          return nil
        end

        @dry_weight_g = dry
        @fired_weight_g = fired
        @loi_measured = true
        @loi_source = :kiln_weights
        @measured_loi_pct = self.class.calculate_kiln_loi(dry_weight_g: dry, fired_weight_g: fired)
      elsif direct_str.present?
        val = parse_strict_float(direct_str.sub(/%\z/, "").strip)
        if val.nil? || val.negative? || val >= 100.0
          @errors << "Measured LOI (%) must be a number between 0 and 99.9."
          return nil
        end

        @loi_measured = true
        @loi_source = :direct_loi
        @measured_loi_pct = val.clamp(0.0, 99.9).round(2)
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
      @errors << "Could not read pXRF CSV file: #{e.message}"
      nil
    end

    def parse_pxrf_csv(content)
      col_sep = detect_separator(content)
      rows = CSV.parse(content, col_sep: col_sep, liberal_parsing: true)
      non_empty_rows = rows.reject { |row| row.nil? || row.all? { |cell| cell.to_s.strip.empty? } }

      if non_empty_rows.empty?
        @errors << "Uploaded pXRF CSV file is empty."
        return {}
      end

      parsed = parse_horizontal_pxrf(non_empty_rows)
      parsed = parse_vertical_pxrf(non_empty_rows) if parsed.empty?

      if parsed.empty?
        @errors << "Could not recognize elemental (% or ppm) or oxide columns in the uploaded pXRF CSV."
      end

      parsed
    rescue CSV::MalformedCSVError => e
      @errors << "Uploaded pXRF CSV could not be parsed: #{e.message}"
      {}
    end

    def detect_separator(content)
      candidate_lines = content.lines.map(&:strip).reject(&:empty?)
      delimited_line = candidate_lines.find { |line| line.match?(/\b(?:si|al|fe|ca|k|sio2|al2o3|rb|sr|zr)\b/i) && line.match?(/[\t,;]/) } ||
        candidate_lines.find { |line| line.match?(/[\t,;]/) } || ""

      counts = {
        "," => delimited_line.count(","),
        "\t" => delimited_line.count("\t"),
        ";" => delimited_line.count(";")
      }
      best_sep, best_count = counts.max_by { |_, count| count }
      best_count.positive? ? best_sep : ","
    end

    def parse_horizontal_pxrf(rows)
      header_idx = rows.index do |row|
        specs = row.filter_map { |cell| parse_column_spec(cell) }
        analyte_specs = specs.select { |s| s[:kind] == :element || s[:kind] == :oxide }
        analyte_specs.map { |s| s[:key] }.uniq.size >= 2
      end
      return {} if header_idx.nil?

      header_specs = rows[header_idx].map { |cell| parse_column_spec(cell) }
      data_start = header_idx + 1

      # Detect an optional Units row right beneath the header (common in Bruker/Olympus exports).
      unit_row_overrides = {}
      if data_start < rows.length && unit_row?(rows[data_start])
        rows[data_start].each_with_index do |cell, idx|
          unit = detect_cell_unit(cell)
          unit_row_overrides[idx] = unit if unit
        end
        data_start += 1
      end

      units_col_idx = header_specs.index { |spec| spec && spec[:kind] == :units }
      sample_id_col_idx = header_specs.index { |spec| spec && spec[:kind] == :sample_id }

      (rows[data_start..] || []).each do |row|
        first_cell = row.first.to_s.strip
        next if first_cell.match?(METADATA_FIRST_CELL_PATTERN)
        next if unit_row?(row)

        row_unit_override = units_col_idx && units_col_idx < row.length ? detect_cell_unit(row[units_col_idx]) : nil

        elements = {}
        oxides = {}

        header_specs.each_with_index do |spec, idx|
          next if spec.nil? || idx >= row.length
          next unless spec[:kind] == :element || spec[:kind] == :oxide

          raw_cell = row[idx]
          num = parse_csv_float(raw_cell)
          next if num.nil?

          unit = spec[:unit] != :unknown ? spec[:unit] : (unit_row_overrides[idx] || row_unit_override || :unknown)
          entry = { value: num, unit: unit }

          if spec[:kind] == :element
            elements[spec[:key]] ||= entry
          else
            oxides[spec[:key]] ||= entry
          end
        end

        next unless has_positive_major_signal?(elements, oxides)

        if sample_id_col_idx && sample_id_col_idx < row.length
          @detected_sample_id = row[sample_id_col_idx].to_s.strip.presence
        end

        return { elements: elements, oxides: oxides }
      end

      {}
    end

    def parse_vertical_pxrf(rows)
      elements = {}
      oxides = {}

      rows.each do |row|
        next if row.length < 2

        spec = parse_column_spec(row[0])
        next unless spec && (spec[:kind] == :element || spec[:kind] == :oxide)

        val_idx = nil
        num = nil
        row[1..].each_with_index do |cell, offset|
          parsed = parse_csv_float(cell)
          if parsed
            num = parsed
            val_idx = offset + 1
            break
          end
        end
        next if num.nil?

        inline_unit = row[(val_idx + 1)..].to_a.filter_map { |c| detect_cell_unit(c) }.first
        unit = spec[:unit] != :unknown ? spec[:unit] : (inline_unit || :unknown)

        if spec[:kind] == :element
          elements[spec[:key]] ||= { value: num, unit: unit }
        else
          oxides[spec[:key]] ||= { value: num, unit: unit }
        end
      end

      return {} unless has_positive_major_signal?(elements, oxides)

      { elements: elements, oxides: oxides }
    end

    def parse_column_spec(raw_header)
      return nil if raw_header.nil?

      text = raw_header.to_s.sub(/\A\uFEFF/, "").strip
      return nil if text.empty?
      return nil if text.match?(ERROR_HEADER_PATTERN)
      return { kind: :units } if text.match?(UNITS_HEADER_PATTERN)
      return { kind: :sample_id } if text.match?(SAMPLE_ID_HEADER_PATTERN)
      return nil if text.match?(SKIP_HEADER_PATTERN)

      spaced = text.tr("_-", " ").gsub(/\s+/, " ").strip
      unit = detect_header_unit(spaced)

      cleaned = spaced
        .gsub("*", "t")
        .gsub(/\([^)]*\)/, " ")
        .gsub(/\[[^\]]*\]/, " ")
        .gsub("%", " ")
        .gsub(/\b(?:wt\s+pct|wt|pct|percent|ppm|ppb|mg\s*\/\s*kg|ug\s*\/\s*g|µg\s*\/\s*g|concentration|conc|pxrf|xrf|result|value|total|tot)\b/i, " ")
        .gsub(/[^a-zA-Z0-9]+/, "")
        .downcase

      return nil if cleaned.empty?

      if (oxide_key = OXIDE_LOOKUP[cleaned])
        return { kind: :oxide, key: oxide_key, unit: unit }
      end

      if (element_key = ELEMENT_LOOKUP[cleaned])
        return { kind: :element, key: element_key, unit: unit }
      end

      nil
    end

    def detect_header_unit(spaced_header)
      return :pct if spaced_header.include?("%") || spaced_header.match?(/\b(?:wt\s+pct|pct|percent)\b/i)
      return :ppm if spaced_header.match?(/\b(?:ppm|mg\s*\/\s*kg|ug\s*\/\s*g|µg\s*\/\s*g)\b/i)
      return :ppb if spaced_header.match?(/\bppb\b/i)

      :unknown
    end

    def detect_cell_unit(cell)
      str = cell.to_s.strip.downcase
      return nil if str.empty?
      return :pct if str == "%" || str.match?(/\A(?:wt\s*%|wt\s*pct|pct|percent)\z/)
      return :ppm if str.match?(/\A(?:ppm|mg\/kg|ug\/g|µg\/g)\z/)
      return :ppb if str == "ppb"

      nil
    end

    def unit_row?(row)
      cells = row.map { |c| c.to_s.strip }.reject(&:empty?)
      return false if cells.size < 2

      unit_matches = cells.count { |c| c.match?(UNIT_ROW_CELL_PATTERN) }
      unit_matches >= 2 && (unit_matches.to_f / cells.size) >= 0.5
    end

    def has_positive_major_signal?(elements, oxides)
      major_el_pos = MAJOR_ELEMENTS.any? { |el| elements[el] && elements[el][:value].positive? }
      major_ox_pos = (FIRED_MAJOR_OXIDES + %w[Fe2O3T FeO]).any? { |ox| oxides[ox] && oxides[ox][:value].positive? }
      major_el_pos || major_ox_pos
    end

    def convert_parsed_chemistry(parsed)
      elements = parsed[:elements] || {}
      oxides = parsed[:oxides] || {}

      # Detect whether bare (unit-unknown) major elements are reported in ppm (sum > 120) or wt%.
      unknown_major_sum = MAJOR_ELEMENTS.sum do |el|
        entry = elements[el]
        entry && entry[:unit] == :unknown ? entry[:value] : 0.0
      end
      bare_major_unit = unknown_major_sum > 120.0 ? :ppm : :pct

      major_oxides = {}
      minor_oxides = {}
      trace_ppm = {}
      csv_loi = nil

      # 1. Direct oxides (when instrument exports in oxide mode)
      fe2o3_total = nil
      fe2o3_ferric = nil
      feo_val = nil

      oxides.each do |oxide_key, entry|
        pct = to_wt_pct(entry[:value], entry[:unit] == :unknown ? :pct : entry[:unit])
        next if pct.nil?

        case oxide_key
        when "LOI"
          csv_loi = pct
        when "Fe2O3T"
          fe2o3_total = pct
        when "Fe2O3"
          fe2o3_ferric = pct
        when "FeO"
          feo_val = pct
        when *FIRED_MAJOR_OXIDES
          major_oxides[oxide_key] = pct
        when *CeramicOxides::MINOR_KEYS
          minor_oxides[oxide_key] = pct.round(4) if pct >= SIGNIFICANT_MINOR_OXIDE_PCT
          back_fill_trace_from_minor_oxide!(trace_ppm, oxide_key, pct)
        end
      end

      if !fe2o3_total.nil?
        major_oxides["Fe2O3"] = fe2o3_total
      elsif !fe2o3_ferric.nil? || !feo_val.nil?
        major_oxides["Fe2O3"] = (fe2o3_ferric || 0.0) + ((feo_val || 0.0) * CeramicOxides::FEO_TO_FE2O3_FACTOR)
      end

      # 2. Elemental major conversions (Si, Al, Fe, Ca, Mg, Na, K, Ti, P, Mn)
      CeramicOxides::ELEMENT_TO_OXIDE_FACTORS.each do |el, spec|
        entry = elements[el]
        next if entry.nil? || !major_oxides[spec[:oxide]].nil?

        resolved_unit = entry[:unit] == :unknown ? bare_major_unit : entry[:unit]
        el_wt_pct = to_wt_pct(entry[:value], resolved_unit)
        next if el_wt_pct.nil?

        major_oxides[spec[:oxide]] = el_wt_pct * spec[:factor]
      end

      # 3. Trace & minor elements (stored in trace_elements_ppm, promoted to minor_oxides when >= 500 ppm / 0.05 wt%)
      TRACE_ELEMENTS.each do |el|
        entry = elements[el]
        next if entry.nil?

        resolved_unit = entry[:unit] == :unknown ? :ppm : entry[:unit]
        ppm_val = to_ppm(entry[:value], resolved_unit)
        next if ppm_val.nil? || !ppm_val.positive?

        trace_ppm[el] = ppm_val.round(2)

        if (minor_spec = CeramicOxides::MINOR_ELEMENT_TO_OXIDE_FACTORS[el])
          oxide_pct = (ppm_val / 10_000.0) * minor_spec[:factor]
          if ppm_val >= SIGNIFICANT_MINOR_PPM || oxide_pct >= SIGNIFICANT_MINOR_OXIDE_PCT
            minor_oxides[minor_spec[:oxide]] ||= oxide_pct.round(4)
          end
        end
      end

      [ major_oxides, minor_oxides, trace_ppm, csv_loi ]
    end

    def back_fill_trace_from_minor_oxide!(trace_ppm, oxide_key, oxide_pct)
      return unless oxide_pct.positive?

      pair = CeramicOxides::MINOR_ELEMENT_TO_OXIDE_FACTORS.find { |_el, spec| spec[:oxide] == oxide_key }
      return unless pair

      element, spec = pair
      return unless TRACE_ELEMENTS.include?(element)

      trace_ppm[element] ||= ((oxide_pct / spec[:factor]) * 10_000.0).round(2)
    end

    def to_wt_pct(value, unit)
      case unit
      when :pct then value.to_f
      when :ppm then value.to_f / 10_000.0
      when :ppb then value.to_f / 10_000_000.0
      else value.to_f
      end
    end

    def to_ppm(value, unit)
      case unit
      when :ppm then value.to_f
      when :pct then value.to_f * 10_000.0
      when :ppb then value.to_f / 1000.0
      else value.to_f
      end
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

    def parse_strict_float(str)
      val = Float(str)
      return nil if val.nan? || val.infinite?

      val
    rescue ArgumentError, TypeError
      nil
    end

    def build_reasoning_log(comparison:, minor_oxides:, trace_ppm:, hazard_report:, effective_loi:)
      entries = []
      qualifier_parts = [ @lab_name, @lab_report_ref || @detected_sample_id ].compact.uniq
      qualifier = qualifier_parts.any? ? " (#{qualifier_parts.join(' · ')})" : ""

      entries << "Handheld pXRF CSV imported#{qualifier} — elemental readings converted to canonical oxides and normalized to 100.00% wt basis."

      case @loi_source
      when :kiln_weights
        entries << "Studio kiln LOI calculated from weights: (#{format('%.2f', @dry_weight_g)} g dry − #{format('%.2f', @fired_weight_g)} g fired) / #{format('%.2f', @dry_weight_g)} g = #{format('%.2f', effective_loi)}% LOI (confidence 90%)."
      when :direct_loi
        entries << "Applied studio-measured LOI of #{format('%.2f', effective_loi)}% (confidence 90%)."
      when :csv
        entries << "Applied CSV-reported LOI of #{format('%.2f', effective_loi)}% (confidence 90%)."
      else
        entries << "No studio kiln LOI supplied — normalized on anhydrous 0.00% LOI basis (confidence 82%; pXRF cannot detect LOI, Li2O, or B2O3)."
      end

      if minor_oxides.any? || trace_ppm.any?
        minor_note = minor_oxides.any? ? "#{minor_oxides.size} minor ceramic oxides (#{minor_oxides.keys.join(', ')})" : "0 minor oxides >= 0.05 wt%"
        entries << "Captured #{trace_ppm.size} trace elements in ppm and #{minor_note}."
      end

      if hazard_report&.k_rb_ratio.present?
        entries << "Pegmatite pathfinder K/Rb mass ratio = #{hazard_report.k_rb_ratio.round(1)}#{' (fractionated LCT pegmatite lithium signal)' if hazard_report.k_rb_ratio < Chemistry::HazardScreenerService::LCT_KRB_THRESHOLD}."
      end

      if comparison.present?
        entries << "Residual calibration vs spatial heuristic: MAE #{format('%.2f', comparison[:mae])} wt%, RMSE #{format('%.2f', comparison[:rmse])} wt%."
      end

      entries
    end

    def upsert_community_reference_assay!(normalized_oxides, minor_oxides, trace_ppm)
      ref_source = "community_verified_xrf"
      external_id = "sample-#{@user_sample.id}-pxrf"

      ref_assay = ReferenceAssay.find_or_initialize_by(source: ref_source, external_id: external_id)
      ref_assay.assign_attributes(
        rock_type: infer_rock_type(@user_sample),
        coordinate_privacy: @coordinate_privacy,
        promoted_by_user: @promoted_by_user,
        oxides: normalized_oxides,
        minor_oxides: minor_oxides,
        trace_elements_ppm: trace_ppm,
        raw_metadata: {
          "sample_title" => @user_sample.title,
          "analysis_method" => "pxrf",
          "lab_name" => @lab_name || "Handheld pXRF",
          "lab_report_ref" => @lab_report_ref || @detected_sample_id,
          "measured_loi_pct" => @measured_loi_pct,
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

    def infer_rock_type(sample)
      category = sample.material_category.to_s
      terms = Array(sample.geologic_unit&.lithology_terms)

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
