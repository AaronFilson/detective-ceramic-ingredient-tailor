# frozen_string_literal: true

require "csv"
require "digest"

module Ingestion
  # Importer for USGS Data Series 801 (Smith et al.) continental soil geochemistry
  # and quantitative Rietveld XRD mineralogy tables (.csv / .tsv / .txt).
  #
  # Handles 45+ major/trace elemental columns (wt% and ppm), quantitative XRD mineral
  # phases, and the real-world DS-801 4-acid ICP-AES/ICP-MS quirk where Si is omitted
  # from the elemental table by estimating SiO2 cleanly from XRD mineral stoichiometry
  # combined with oxide + estimated-LOI mass balance.
  class UsgsDs801Importer
    DEFAULT_SOURCE = "usgs_ds801"
    MINOR_OXIDE_THRESHOLD_WT_PCT = 0.001

    LATITUDE_KEYS = %w[latitude lat lat_dd lat_wgs84 dec_lat latitude_dd y].freeze
    LONGITUDE_KEYS = %w[longitude lng lon long lon_dd lng_dd long_dd lon_wgs84 dec_long dec_lon longitude_dd x].freeze
    EXPLICIT_ID_KEYS = %w[lab_id labid sample_id external_id field_id].freeze
    SITE_ID_KEYS = %w[siteid site_id id].freeze
    HORIZON_KEYS = %w[horizon soil_horizon hz layer depth_horizon].freeze
    ROCK_TYPE_KEYS = %w[rock_type rock_name lithology material].freeze
    PARENT_MATERIAL_KEYS = %w[parent_material geology formation soil_order locality state].freeze

    MISSING_TOKENS = /\A(?:|na|n\/a|nd|bdl|ns|n\.s\.|n|null|none|nan|--+|-)\z/i

    OXIDE_PATTERNS = {
      "SiO2" => /\Asio2(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "Al2O3" => /\Aal2o3(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "Fe2O3T" => /\Afe2o3(?:t|_?tot(?:al)?)(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes))*\z/,
      "Fe2O3" => /\Afe2o3(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes))*\z/,
      "FeO" => /\Afeo(?:t|_?tot(?:al)?)?(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes))*\z/,
      "CaO" => /\Acao(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "MgO" => /\Amgo(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "Na2O" => /\Ana2o(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "K2O" => /\Ak2o(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "TiO2" => /\Atio2(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "P2O5" => /\Ap2o5(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "MnO" => /\Amno(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms|oes|aes|tot|total))*\z/,
      "LOI" => /\A(?:loi|loss_on_ignition)(?:_(?:wt_?pct|wt|pct|percent))*\z/
    }.freeze

    # Additional DS-801 ICP-MS/ICP-AES trace elements beyond CeramicOxides::TRACE_ELEMENT_KEYS.
    EXTRA_TRACE_ELEMENTS = %w[Ag Be Bi Ga Hg In La Mo Sb Sc Se Te Tl W Y].freeze
    ALL_TRACE_ELEMENTS = (CeramicOxides::TRACE_ELEMENT_KEYS + EXTRA_TRACE_ELEMENTS).uniq.freeze

    # Canonical quantitative Rietveld XRD mineral keys and accepted header aliases.
    XRD_MINERAL_PATTERNS = {
      "quartz" => /\A(?:quartz|qtz)(?:_(?:wt_?pct|wt|pct|percent|xrd))*\z/,
      "k_feldspar" => /\A(?:total_k_feldspar|k_feldspar|kfeldspar|potassium_feldspar|orthoclase|microcline)(?:_(?:wt_?pct|wt|pct|percent|xrd))*\z/,
      "plagioclase" => /\A(?:total_plagioclase|plagioclase|plag|albite|anorthite)(?:_(?:wt_?pct|wt|pct|percent|xrd))*\z/,
      "total_clays" => /\A(?:total_clays|total_clay|total_phyllosilicates)(?:_(?:wt_?pct|wt|pct|percent|xrd))*\z/,
      "kaolinite" => /\A(?:kaolinite|kaolin)(?:_(?:wt_?pct|wt|pct|percent|xrd))*\z/,
      "illite" => /\A(?:illite|illite_mica|muscovite|total_10a_clays)(?:_(?:wt_?pct|wt|pct|percent|xrd))*\z/,
      "smectite" => /\A(?:smectite|montmorillonite|expandable_clays|total_14a_clays|vermiculite)(?:_(?:wt_?pct|wt|pct|percent|xrd))*\z/,
      "chlorite" => /\Achlorite(?:_(?:wt_?pct|wt|pct|percent|xrd))*\z/,
      "calcite" => /\Acalcite(?:_(?:wt_?pct|wt|pct|percent|xrd))*\z/,
      "dolomite" => /\Adolomite(?:_(?:wt_?pct|wt|pct|percent|xrd))*\z/,
      "hornblende" => /\A(?:hornblende|amphibole)(?:_(?:wt_?pct|wt|pct|percent|xrd))*\z/,
      "hematite" => /\A(?:hematite|goethite|iron_oxides)(?:_(?:wt_?pct|wt|pct|percent|xrd))*\z/,
      "gypsum" => /\Agypsum(?:_(?:wt_?pct|wt|pct|percent|xrd))*\z/,
      "pyrite" => /\Apyrite(?:_(?:wt_?pct|wt|pct|percent|xrd))*\z/,
      "amorphous" => /\A(?:amorphous|amorphous_material)(?:_(?:wt_?pct|wt|pct|percent|xrd))*\z/
    }.freeze

    CLAY_MINERAL_KEYS = %w[kaolinite illite smectite chlorite].freeze
    SILICATE_XRD_KEYS = %w[quartz k_feldspar plagioclase total_clays kaolinite illite smectite chlorite hornblende].freeze

    # Stoichiometric SiO2, Al2O3, and volatile LOI weight fractions by XRD mineral phase.
    XRD_SIO2_FRACTIONS = {
      "quartz" => 1.000,
      "k_feldspar" => 0.648,
      "plagioclase" => 0.620,
      "kaolinite" => 0.465,
      "illite" => 0.480,
      "smectite" => 0.550,
      "chlorite" => 0.300,
      "total_clays" => 0.500,
      "hornblende" => 0.450
    }.freeze

    XRD_AL2O3_FRACTIONS = {
      "k_feldspar" => 0.183,
      "plagioclase" => 0.240,
      "kaolinite" => 0.395,
      "illite" => 0.260,
      "smectite" => 0.200,
      "chlorite" => 0.180,
      "total_clays" => 0.260,
      "hornblende" => 0.110
    }.freeze

    XRD_LOI_FRACTIONS = {
      "kaolinite" => 0.140,
      "illite" => 0.060,
      "smectite" => 0.120,
      "chlorite" => 0.120,
      "total_clays" => 0.100,
      "calcite" => 0.440,
      "dolomite" => 0.477,
      "gypsum" => 0.209,
      "hornblende" => 0.020
    }.freeze

    def initialize(input, source: DEFAULT_SOURCE, bulk: false)
      @input = input
      @source = source.to_s
      @bulk = bulk
    end

    def call
      created = 0
      updated = 0
      skipped = 0
      errors = []

      content = read_input_content
      col_sep = detect_separator(content)
      rows = CSV.parse(content, headers: true, col_sep: col_sep, liberal_parsing: true)

      rows.each_with_index.each_slice(500) do |batch|
        counts =
          if @bulk
            import_batch_bulk(batch, errors)
          else
            import_batch_individual(batch, errors)
          end

        created += counts[:created]
        updated += counts[:updated]
        skipped += counts[:skipped]
      end

      ImportResult.new(
        imported: created + updated,
        created: created,
        updated: updated,
        skipped: skipped,
        errors: errors
      )
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
            xrd_mineralogy: attrs[:xrd_mineralogy],
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

      lat = extract_coordinate(normalized_row, LATITUDE_KEYS, -90.0..90.0)
      lng = extract_coordinate(normalized_row, LONGITUDE_KEYS, -180.0..180.0)
      if lat.nil? || lng.nil?
        errors << { row: row_num, reason: "Missing or invalid latitude/longitude" }
        return nil
      end

      xrd_mineralogy = extract_xrd_mineralogy(normalized_row)
      raw_oxides = extract_major_oxides(normalized_row)
      has_direct_si = raw_oxides["SiO2"].to_f.positive?
      has_direct_al = raw_oxides["Al2O3"].to_f.positive?

      if !has_direct_si && !has_direct_al
        errors << { row: row_num, reason: "Missing both valid Si/SiO2 and Al/Al2O3" }
        return nil
      end

      estimated_sio2 = false
      estimated_al2o3 = false
      raw_oxides["LOI"] ||= estimate_loi(normalized_row, xrd_mineralogy, raw_oxides["Al2O3"])

      if !has_direct_si
        est_si = estimate_sio2_from_xrd_and_balance(raw_oxides, xrd_mineralogy)
        if est_si.nil? || !est_si.positive?
          errors << { row: row_num, reason: "Missing Si/SiO2 and silicate XRD mineralogy for mass-balance estimation" }
          return nil
        end

        raw_oxides["SiO2"] = est_si
        estimated_sio2 = true
      end

      if !has_direct_al
        est_al = estimate_al2o3_from_xrd(xrd_mineralogy)
        if est_al.nil? || !est_al.positive?
          errors << { row: row_num, reason: "Missing Al/Al2O3 and aluminosilicate XRD mineralogy" }
          return nil
        end

        raw_oxides["Al2O3"] = est_al
        estimated_al2o3 = true
      end

      normalized_oxides = CeramicOxides.normalize(raw_oxides)
      if normalized_oxides.nil?
        errors << { row: row_num, reason: "Oxide total must be positive" }
        return nil
      end

      trace_elements_ppm = extract_trace_elements(normalized_row)
      minor_oxides = extract_minor_oxides(normalized_row, trace_elements_ppm)
      horizon_token = extract_horizon_token(normalized_row)
      sample_media = "soil_#{horizon_token}_horizon"
      rock_type = extract_explicit_rock_type(normalized_row) || infer_soil_rock_type(xrd_mineralogy, normalized_row)
      external_id = extract_external_id(normalized_row, horizon_token, lat, lng, rock_type, normalized_oxides)

      raw_metadata = build_raw_metadata(row)
      raw_metadata["sio2_estimated"] = true if estimated_sio2
      raw_metadata["al2o3_estimated"] = true if estimated_al2o3

      {
        source: @source,
        external_id: external_id,
        rock_type: rock_type,
        sample_media: sample_media,
        location: Geolocatable.factory.point(lng, lat),
        oxides: normalized_oxides,
        minor_oxides: minor_oxides,
        trace_elements_ppm: trace_elements_ppm,
        xrd_mineralogy: xrd_mineralogy,
        raw_metadata: raw_metadata
      }
    end

    def extract_major_oxides(normalized_row)
      direct = {}
      fe2o3_total = nil
      fe2o3_ferric = nil
      feo_val = nil

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

      if !fe2o3_total.nil?
        direct["Fe2O3"] = fe2o3_total
      elsif !fe2o3_ferric.nil? || !feo_val.nil?
        direct["Fe2O3"] = (fe2o3_ferric || 0.0) + ((feo_val || 0.0) * CeramicOxides::FEO_TO_FE2O3_FACTOR)
      end

      CeramicOxides::ELEMENT_TO_OXIDE_FACTORS.each do |element, spec|
        oxide = spec[:oxide]
        next unless direct[oxide].nil?

        el_wt_pct = extract_element_wt_pct(normalized_row, element)
        next if el_wt_pct.nil?

        direct[oxide] = el_wt_pct * spec[:factor]
      end

      direct
    end

    def extract_xrd_mineralogy(normalized_row)
      xrd = {}

      normalized_row.each do |key, raw_val|
        val = parse_float(raw_val, allow_negative: false)
        next if val.nil? || !val.positive?

        XRD_MINERAL_PATTERNS.each do |mineral, pattern|
          if key.match?(pattern)
            xrd[mineral] ||= val.round(2)
            break
          end
        end
      end

      xrd
    end

    def extract_trace_elements(normalized_row)
      traces = {}

      ALL_TRACE_ELEMENTS.each do |element|
        ppm = extract_element_ppm(normalized_row, element)
        next if ppm.nil? || !ppm.positive?

        traces[element] = ppm.round(2)
      end

      traces
    end

    def extract_minor_oxides(normalized_row, trace_elements_ppm)
      minors = {}

      CeramicOxides::MINOR_ELEMENT_TO_OXIDE_FACTORS.each do |element, spec|
        oxide = spec[:oxide]
        direct_pattern = /\A#{oxide.downcase}(?:_(?:wt_?pct|wt|pct|percent|xrf|icp|icpms))*\z/

        direct_val = nil
        normalized_row.each do |key, raw_val|
          next unless key.match?(direct_pattern)

          val = parse_float(raw_val, allow_negative: false)
          if val && val.positive?
            direct_val = val
            break
          end
        end

        oxide_wt_pct =
          if direct_val
            direct_val
          elsif trace_elements_ppm[element].to_f.positive?
            (trace_elements_ppm[element].to_f / 10_000.0) * spec[:factor]
          end

        next if oxide_wt_pct.nil? || oxide_wt_pct < MINOR_OXIDE_THRESHOLD_WT_PCT

        minors[oxide] = oxide_wt_pct.round(4)
      end

      minors
    end

    def estimate_loi(normalized_row, xrd_mineralogy, al2o3_val)
      loi = 0.0

      if xrd_mineralogy.any?
        effective_minerals = effective_xrd_breakdown(xrd_mineralogy)
        effective_minerals.each do |mineral, pct|
          frac = XRD_LOI_FRACTIONS[mineral]
          loi += pct * frac if frac
        end
      end

      c_org = parse_float(normalized_row["c_org_pct"] || normalized_row["org_c_pct"] || normalized_row["organic_carbon_pct"], allow_negative: false)
      loi += [ c_org * 1.724, 12.0 ].min if c_org&.positive?

      if loi <= 0.0 && al2o3_val.to_f.positive?
        loi = (al2o3_val.to_f * 0.25).clamp(1.0, 12.0)
      end

      loi.round(4)
    end

    def estimate_sio2_from_xrd_and_balance(raw_oxides, xrd_mineralogy)
      silicate_present = SILICATE_XRD_KEYS.any? { |k| xrd_mineralogy[k].to_f.positive? }
      return nil unless silicate_present

      effective_minerals = effective_xrd_breakdown(xrd_mineralogy)
      xrd_sio2 = effective_minerals.sum { |mineral, pct| pct * XRD_SIO2_FRACTIONS.fetch(mineral, 0.0) }
      xrd_total = effective_minerals.values.sum

      other_sum = raw_oxides.except("SiO2").values.sum(&:to_f)
      mass_balance_sio2 = 100.0 - other_sum

      estimated =
        if xrd_sio2.positive? && mass_balance_sio2.positive?
          if xrd_total >= 50.0
            (0.5 * xrd_sio2) + (0.5 * mass_balance_sio2)
          else
            mass_balance_sio2
          end
        elsif mass_balance_sio2.positive?
          mass_balance_sio2
        elsif xrd_sio2.positive?
          xrd_sio2
        end

      estimated&.positive? ? estimated.round(4) : nil
    end

    def estimate_al2o3_from_xrd(xrd_mineralogy)
      return nil if xrd_mineralogy.empty?

      effective_minerals = effective_xrd_breakdown(xrd_mineralogy)
      al2o3 = effective_minerals.sum { |mineral, pct| pct * XRD_AL2O3_FRACTIONS.fetch(mineral, 0.0) }
      al2o3.positive? ? al2o3.round(4) : nil
    end

    # Prevents double-counting Total_Clays alongside individual clay phases
    # (kaolinite, illite, smectite, chlorite) during stoichiometric estimates.
    def effective_xrd_breakdown(xrd_mineralogy)
      breakdown = xrd_mineralogy.dup
      individual_clay_sum = CLAY_MINERAL_KEYS.sum { |k| breakdown[k].to_f }

      if breakdown.key?("total_clays") && individual_clay_sum.positive?
        remainder = (breakdown["total_clays"].to_f - individual_clay_sum).round(2)
        if remainder.positive?
          breakdown["total_clays"] = remainder
        else
          breakdown.delete("total_clays")
        end
      end

      breakdown
    end

    def infer_soil_rock_type(xrd_mineralogy, normalized_row)
      kaolinite = xrd_mineralogy["kaolinite"].to_f
      illite = xrd_mineralogy["illite"].to_f
      smectite = xrd_mineralogy["smectite"].to_f
      chlorite = xrd_mineralogy["chlorite"].to_f
      individual_clays = kaolinite + illite + smectite + chlorite
      total_clay = [ xrd_mineralogy["total_clays"].to_f, individual_clays ].max
      carbonate = xrd_mineralogy["calcite"].to_f + xrd_mineralogy["dolomite"].to_f
      quartz = xrd_mineralogy["quartz"].to_f

      return "kaolin_clay" if kaolinite >= 25.0 || (total_clay >= 20.0 && kaolinite >= (total_clay * 0.6))
      return "marl" if carbonate >= 15.0
      return "siltstone" if quartz >= 55.0 && total_clay < 18.0

      context = PARENT_MATERIAL_KEYS.filter_map { |k| normalized_row[k]&.to_s&.strip }.join(" ")
      return "glacial_clay" if context.match?(/\b(?:glacial|till|drift|moraine|vashon|wisconsin\w*|des\s+moines\s+lobe)\b/i)
      return "marine_clay" if context.match?(/\b(?:glaciomarine|marine|estuar\w*|tidal)\b/i)
      return "loess" if context.match?(/\b(?:loess|palouse|eolian|windblown)\b/i)
      return "alluvial_clay" if context.match?(/\b(?:alluv\w*|fluvial|floodplain|river|valley|terrace|underclay)\b/i)

      return "glacial_clay" if (xrd_mineralogy["plagioclase"].to_f + xrd_mineralogy["hornblende"].to_f) >= 22.0 && total_clay < 35.0
      return "alluvial_clay" if total_clay >= 22.0 || smectite >= 12.0
      return "siltstone" if quartz >= 45.0

      "alluvial_clay"
    end

    def extract_explicit_rock_type(normalized_row)
      ROCK_TYPE_KEYS.each do |key|
        val = normalized_row[key]&.to_s&.strip
        return val.downcase if val && !val.empty? && !val.match?(MISSING_TOKENS)
      end
      nil
    end

    def extract_horizon_token(normalized_row)
      HORIZON_KEYS.each do |key|
        raw = normalized_row[key]&.to_s&.strip
        next if raw.nil? || raw.empty? || raw.match?(MISSING_TOKENS)

        token = raw.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_+|_+\z/, "")
        token = token.sub(/_?horizon\z/, "").sub(/\Asoil_/, "")
        token = "top5" if token == "top5cm" || token == "0_5cm" || token == "0_5"
        return token unless token.empty?
      end

      "c"
    end

    def extract_external_id(normalized_row, horizon_token, lat, lng, rock_type, normalized_oxides)
      EXPLICIT_ID_KEYS.each do |key|
        val = normalized_row[key]&.to_s&.strip
        return val if val && !val.empty? && !val.match?(MISSING_TOKENS)
      end

      SITE_ID_KEYS.each do |key|
        val = normalized_row[key]&.to_s&.strip
        next unless val && !val.empty? && !val.match?(MISSING_TOKENS)

        suffix = horizon_token.upcase
        return val if val.match?(/[-_]#{Regexp.escape(suffix)}\z/i)

        return "#{val}-#{suffix}"
      end

      payload = [
        @source,
        horizon_token,
        format("%.6f", lat),
        format("%.6f", lng),
        rock_type.to_s,
        CeramicOxides::KEYS.map { |k| format("%.4f", normalized_oxides[k].to_f) }.join(",")
      ].join("|")
      "sha256:#{Digest::SHA256.hexdigest(payload)[0, 24]}"
    end

    def extract_element_wt_pct(normalized_row, element)
      el = element.downcase
      pct_pattern = /\A#{el}(?:_(?:icp|icpms|oes|aes|xrf|ms|40|42|tot|total))*_(?:wt_?pct|wt|pct|percent)\z/
      ppm_pattern = /\A#{el}(?:_(?:icp|icpms|oes|aes|xrf|ms|40|42|tot|total))*_ppm\z/

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

      nil
    end

    def extract_element_ppm(normalized_row, element)
      el = element.downcase
      ppm_pattern = /\A#{el}(?:_(?:icp|icpms|oes|aes|xrf|ms|40|42|tot|total))*_ppm\z/
      pct_pattern = /\A#{el}(?:_(?:icp|icpms|oes|aes|xrf|ms|40|42|tot|total))*_(?:wt_?pct|wt|pct|percent)\z/

      normalized_row.each do |key, raw_val|
        next unless key.match?(ppm_pattern)

        val = parse_float(raw_val, allow_negative: false)
        return val unless val.nil?
      end

      normalized_row.each do |key, raw_val|
        next unless key.match?(pct_pattern)

        val = parse_float(raw_val, allow_negative: false)
        return val * 10_000.0 unless val.nil?
      end

      nil
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
      first_line.include?("\t") && !first_line.include?(",") ? "\t" : ","
    end

    def canonicalize_header(header)
      return nil if header.nil?

      header
        .to_s
        .sub(/\A\uFEFF/, "")
        .strip
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
