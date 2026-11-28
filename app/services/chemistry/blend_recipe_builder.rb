# frozen_string_literal: true

module Chemistry
  # Computes 2-material line blends (0/100..100/0, 11 steps) and 3-material
  # triaxial simplex blends (5% step, 231 candidates) across assayed local
  # UserSamples and commercial Studio Stock Modifiers. Blends both major and
  # minor ceramic oxides (including Cone 6 B2O3 and Li2O/SrO/ZnO), scores each
  # candidate against Cone 6 / Cone 10 Gloss & Matte Seger UMF target bands,
  # classifies Stull zones, predicts Appen/English-Turner thermal expansion COE,
  # and exports combined Materials + Recipe bundles for Glazecalc and Glaze Vault.
  class BlendRecipeBuilder
    LINE_BLEND_STEP = 10
    TRIAXIAL_STEP = 5

    BLENDABLE_MINOR_KEYS = (CeramicOxides::MINOR_KEYS - %w[SO3 F]).freeze

    STULL_ZONES = [
      "Gloss",
      "Matte",
      "Crazing / High-Silica",
      "Unfused / Refractory",
      "Underfired / High-Flux"
    ].freeze

    TARGET_BANDS = {
      [ "6", "gloss" ] => {
        label: "Cone 6 Gloss",
        firing: "mid",
        cone: "6",
        surface: "gloss",
        sio2: 3.0..4.2,
        al2o3: 0.32..0.48,
        si_al: 6.5..9.5,
        flux_axis: :r2o,
        r2o: 0.20..0.45,
        ro: 0.55..0.80,
        b2o3: 0.12..0.32
      }.freeze,
      [ "6", "matte" ] => {
        label: "Cone 6 Matte",
        firing: "mid",
        cone: "6",
        surface: "matte",
        sio2: 2.4..3.5,
        al2o3: 0.40..0.60,
        si_al: 4.5..6.8,
        flux_axis: :ro,
        ro: 0.60..0.85,
        r2o: 0.15..0.40,
        b2o3: 0.12..0.32
      }.freeze,
      [ "10", "gloss" ] => {
        label: "Cone 10 Gloss",
        firing: "high",
        cone: "10",
        surface: "gloss",
        sio2: 3.5..5.0,
        al2o3: 0.38..0.55,
        si_al: 7.0..10.0,
        flux_axis: :ro,
        ro: 0.60..0.85,
        r2o: 0.15..0.40
      }.freeze,
      [ "10", "matte" ] => {
        label: "Cone 10 Matte",
        firing: "high",
        cone: "10",
        surface: "matte",
        sio2: 2.6..3.8,
        al2o3: 0.45..0.68,
        si_al: 4.5..6.5,
        flux_axis: :ro,
        ro: 0.65..0.90,
        r2o: 0.10..0.35
      }.freeze
    }.freeze

    STOCK_GLAZE_VAULT_CLASSES = {
      "epk_kaolin" => "kaolin",
      "om4_ball_clay" => "ball clay",
      "silica" => "silica",
      "talc" => "talc",
      "wollastonite" => "wollastonite",
      "nepheline_syenite" => "nepheline syenite",
      "custer_feldspar" => "feldspar",
      "minspar_200" => "feldspar"
    }.freeze

    Candidate = Struct.new(
      :weights,
      :oxides,
      :minor_oxides,
      :umf,
      :coe_report,
      :penalty,
      :fit_score,
      :stull_zone,
      :band_checks,
      keyword_init: true
    ) do
      def sio2
        umf.dig("glass_formers", "SiO2").to_f
      end

      def al2o3
        umf.dig("intermediates", "Al2O3").to_f
      end

      def b2o3
        umf.dig("intermediates", "B2O3").to_f
      end

      def li2o
        umf.dig("fluxes", "Li2O").to_f
      end

      def si_al_ratio
        umf["si_al_ratio"]
      end

      def r2o_total
        umf["r2o_total"].to_f
      end

      def ro_total
        umf["ro_total"].to_f
      end

      def coe
        coe_report&.coe
      end

      def crazing_risk
        coe_report&.risk_level
      end

      def all_in_band?
        band_checks.values.all?
      end

      def positive_weights
        weights.select { |entry| entry[:percentage].to_f.positive? }
      end

      def batch_label
        weights.map { |entry| "#{entry[:percentage]}%" }.join(" / ")
      end
    end

    BlendResult = Struct.new(
      :mode,
      :samples,
      :target_cone,
      :surface,
      :target_band,
      :optimal,
      :candidates,
      :ranked_candidates,
      :b2o3_missing_cone6,
      keyword_init: true
    ) do
      def line_blend?
        mode == :line_blend
      end

      def triaxial?
        mode == :triaxial
      end

      def b2o3_missing_cone6?
        !!b2o3_missing_cone6
      end

      def top_candidates(limit = 12)
        ranked_candidates.first(limit)
      end

      def zone_counts
        candidates.each_with_object(Hash.new(0)) do |candidate, counts|
          counts[candidate.stull_zone] += 1
        end
      end

      def default_recipe_title
        names = optimal.positive_weights.map { |w| w[:sample].title.to_s }
        "#{names.join(' + ')} (Cone #{target_cone} #{surface.capitalize})"
      end
    end

    def self.call(samples:, target_cone: "6", surface: "gloss")
      new(samples: samples, target_cone: target_cone, surface: surface).call
    end

    def self.classify_stull_zone(umf)
      return "Unfused / Refractory" unless umf.is_a?(Hash) && umf["flux_total"].to_f.positive?

      sio2 = umf.dig("glass_formers", "SiO2").to_f
      al2o3 = umf.dig("intermediates", "Al2O3").to_f
      si_al = umf["si_al_ratio"]&.to_f

      return "Underfired / High-Flux" if sio2 < 2.0 || (al2o3 < 0.20 && sio2 < 2.6)
      return "Unfused / Refractory" if al2o3 > 0.75 || sio2 > 6.0 || (al2o3 > 0.65 && sio2 > 4.5)
      return "Crazing / High-Silica" if (si_al.present? && si_al > 10.5) || (sio2 > 5.0 && al2o3 < 0.55) || (al2o3 < 0.28 && sio2 >= 2.6)
      return "Matte" if si_al.present? && si_al <= 6.8 && al2o3 >= 0.30 && sio2 <= 4.3
      return "Gloss" if si_al.present? && si_al > 6.8 && si_al <= 10.5 && al2o3 >= 0.28 && sio2 >= 2.8 && sio2 <= 5.2
      return "Matte" if al2o3 >= 0.40 && sio2 < 2.8

      sio2 >= 3.5 ? "Crazing / High-Silica" : "Underfired / High-Flux"
    end

    def self.to_glazecalc_export(blend_result, recipe_title: nil, candidate: nil)
      chosen = candidate || blend_result.optimal
      title = recipe_title.to_s.strip.presence || blend_result.default_recipe_title
      firing = blend_result.target_band.fetch(:firing)

      serialized_materials = blend_result.samples.map do |sample|
        serialize_glazecalc_material(sample)
      end

      recipe_materials = chosen.positive_weights.map do |entry|
        {
          "name" => entry[:sample].title.to_s,
          "amount" => entry[:percentage]
        }
      end

      {
        "format" => Exporters::GlazecalcMaterialSerializer::EXPORT_FORMAT,
        "version" => Exporters::GlazecalcMaterialSerializer::EXPORT_VERSION,
        "exportedAt" => Time.current.utc.iso8601,
        "records" => {
          "materials" => serialized_materials,
          "recipes" => [
            {
              "title" => title,
              "materials" => recipe_materials,
              "notes" => build_recipe_notes(blend_result, chosen),
              "firing" => firing
            }
          ]
        }
      }
    end

    def self.to_glaze_vault_export(blend_result, recipe_title: nil, candidate: nil)
      chosen = candidate || blend_result.optimal
      title = recipe_title.to_s.strip.presence || blend_result.default_recipe_title
      now_iso = Time.current.utc.iso8601

      serialized_materials = blend_result.samples.map do |sample|
        serialize_glaze_vault_material(sample, now_iso)
      end

      recipe_lines = chosen.positive_weights.map do |entry|
        {
          "material" => entry[:sample].title.to_s,
          "amount" => entry[:percentage]
        }
      end

      stock_keys = blend_result.samples.filter_map do |sample|
        sample.key if stock_material?(sample)
      end

      provenance = {
        "generator" => "Chemistry::BlendRecipeBuilder",
        "mode" => blend_result.mode.to_s,
        "target_cone" => blend_result.target_cone,
        "surface" => blend_result.surface,
        "stull_zone" => chosen.stull_zone,
        "fit_score" => chosen.fit_score,
        "umf_formula" => chosen.umf,
        "minor_oxides" => chosen.minor_oxides || {},
        "sample_ids" => blend_result.samples.map(&:id)
      }
      provenance["stock_keys"] = stock_keys if stock_keys.any?
      if chosen.coe_report.present?
        provenance["coe"] = chosen.coe
        provenance["crazing_risk"] = chosen.crazing_risk.to_s
      end

      {
        "format" => Exporters::GlazeVaultSerializer::FORMAT_NAME,
        "version" => Exporters::GlazeVaultSerializer::EXPORT_VERSION,
        "exportedAt" => now_iso,
        "appVersion" => Exporters::GlazeVaultSerializer::APP_VERSION,
        "recipes" => [
          {
            "name" => title,
            "type" => "glaze",
            "cone" => blend_result.target_cone.to_s,
            "surface" => blend_result.surface.to_s,
            "lines" => recipe_lines,
            "notes" => build_recipe_notes(blend_result, chosen)
          }
        ],
        "materials" => serialized_materials,
        "provenance" => provenance
      }
    end

    def self.stock_material?(sample)
      sample.respond_to?(:stock?) && sample.stock?
    end
    private_class_method :stock_material?

    def self.serialize_glazecalc_material(sample)
      return Exporters::GlazecalcMaterialSerializer.call(sample) unless stock_material?(sample)

      normalized = Exporters::GlazecalcMaterialSerializer.normalize_oxides(
        sample.oxides,
        minor_oxides: sample.minor_oxides
      )
      loi = normalized.fetch("LOI")
      fired_keys = normalized.keys - [ "LOI" ]
      molar_masses = CeramicOxides::ALL_OXIDE_MOLAR_WEIGHTS

      moles_per_gram = fired_keys.each_with_object({}) do |oxide, acc|
        acc[oxide] = (normalized[oxide] / 100.0) / molar_masses.fetch(oxide)
      end

      flux_per_gram = (fired_keys & Chemistry::UmfCalculator::ALL_FLUX_OXIDES).sum { |oxide| moles_per_gram[oxide] }
      raw_equivalent = flux_per_gram.positive? ? (1.0 / flux_per_gram) : 100.0
      equivalent = raw_equivalent.round(2)
      formulaweight = (equivalent * (1.0 - loi / 100.0)).round(2)

      fields = fired_keys.filter_map do |oxide|
        pct = normalized[oxide]
        next unless pct.positive?

        {
          "name" => oxide,
          "amount" => format("%.2f", pct),
          "amountUnity" => (moles_per_gram[oxide] * raw_equivalent).round(4)
        }
      end

      oxide_analysis = fired_keys.each_with_object({}) do |oxide, acc|
        pct = normalized[oxide]
        acc[oxide] = pct if pct.positive?
      end

      rawformula_entries = fired_keys.filter_map do |oxide|
        pct = normalized[oxide]
        next unless pct.positive?

        "#{oxide} #{format('%.2f', pct)}%"
      end
      rawformula_entries << "LOI #{format('%.2f', loi)}%" if loi.positive?

      {
        "name" => sample.title.to_s,
        "fields" => fields,
        "percentmole" => "percent",
        "loi" => loi,
        "molecularweight" => 100.0,
        "equivalent" => equivalent,
        "formulaweight" => formulaweight,
        "rawformula" => rawformula_entries.join(", "),
        "analysis" => oxide_analysis,
        "oxideAnalysis" => oxide_analysis,
        "oxides" => normalized,
        "umf" => Exporters::GlazecalcMaterialSerializer.compute_umf(normalized),
        "source" => {
          "kind" => "studio_stock_catalog",
          "application" => Exporters::GlazecalcMaterialSerializer::APPLICATION_NAME,
          "stock_key" => sample.key,
          "sample_id" => sample.id,
          "role" => sample.role,
          "generated_at" => Time.current.utc.iso8601
        },
        "notes" => [ sample.notes.to_s.strip ].reject(&:empty?),
        "relatedTo" => [ sample.role.to_s, sample.material_category.to_s.tr("_", " ") ].reject(&:blank?).uniq
      }
    end
    private_class_method :serialize_glazecalc_material

    def self.serialize_glaze_vault_material(sample, now_iso)
      return Exporters::GlazeVaultSerializer.call(sample).fetch("materials").first unless stock_material?(sample)

      normalized = Exporters::GlazecalcMaterialSerializer.normalize_oxides(
        sample.oxides,
        minor_oxides: sample.minor_oxides
      )
      fired_keys = normalized.keys - [ "LOI" ]
      oxide_entries = fired_keys.filter_map do |oxide|
        pct = normalized[oxide]
        next unless pct.positive?

        {
          "oxide" => oxide,
          "percent" => format("%.2f", pct)
        }
      end

      {
        "name" => sample.title.to_s,
        "category" => "material",
        "oxides" => oxide_entries,
        "loi" => format("%.2f", normalized.fetch("LOI")),
        "class" => STOCK_GLAZE_VAULT_CLASSES.fetch(sample.key.to_s, "other"),
        "notes" => sample.notes.to_s.strip,
        "revision" => 1,
        "savedAt" => now_iso
      }
    end
    private_class_method :serialize_glaze_vault_material

    def self.build_recipe_notes(blend_result, candidate)
      mode_label = blend_result.line_blend? ? "Line Blend (10% steps)" : "Triaxial Blend (5% simplex)"
      si_al_str = candidate.si_al_ratio.present? ? format("%.2f", candidate.si_al_ratio) : "n/a"

      minor_umf_bits = []
      minor_umf_bits << format("B2O3 %.2f", candidate.b2o3) if candidate.b2o3.positive?
      minor_umf_bits << format("Li2O %.2f", candidate.li2o) if candidate.li2o.positive?
      %w[SrO BaO ZnO].each do |oxide|
        val = candidate.umf.dig("fluxes", oxide).to_f
        minor_umf_bits << format("%s %.2f", oxide, val) if val.positive?
      end
      minor_suffix = minor_umf_bits.any? ? ", #{minor_umf_bits.join(', ')}" : ""

      parts = [
        "Generated by DCI Tailor #{mode_label} targeting #{blend_result.target_band[:label]}.",
        format(
          "Predicted UMF: SiO2 %.2f, Al2O3 %.2f, Si:Al %s, R2O %.2f, RO %.2f%s (%s, Fit %.1f%%).",
          candidate.sio2,
          candidate.al2o3,
          si_al_str,
          candidate.r2o_total,
          candidate.ro_total,
          minor_suffix,
          candidate.stull_zone,
          candidate.fit_score
        )
      ]

      if candidate.coe_report.present?
        parts << format(
          "Predicted COE: %.2f x10^-7/C (%s).",
          candidate.coe_report.coe,
          candidate.coe_report.risk_label
        )
      end

      parts << "Batch: #{candidate.positive_weights.map { |w| "#{w[:percentage]}% #{w[:sample].title}" }.join(', ')}."
      parts.join(" ")
    end
    private_class_method :build_recipe_notes

    def initialize(samples:, target_cone: "6", surface: "gloss")
      @samples = Array(samples).compact
      @target_cone = normalize_cone(target_cone)
      @surface = normalize_surface(surface)
      @target_band = TARGET_BANDS.fetch([ @target_cone, @surface ])
    end

    def call
      validate_samples!
      normalized_entries = @samples.map { |sample| normalize_input_entry(sample) }

      @has_boron_source = normalized_entries.any? do |entry|
        entry[:minor_oxides].fetch("B2O3", 0.0).positive?
      end
      @score_b2o3 = @target_band[:b2o3].present? && @has_boron_source

      mode = @samples.size == 2 ? :line_blend : :triaxial
      percentage_grid = mode == :line_blend ? build_line_blend_grid : build_triaxial_grid

      candidates = percentage_grid.map do |percentages|
        evaluate_candidate(normalized_entries, percentages)
      end

      ranked = candidates.sort_by do |candidate|
        [ candidate.penalty, -candidate.fit_score ]
      end

      BlendResult.new(
        mode: mode,
        samples: @samples,
        target_cone: @target_cone,
        surface: @surface,
        target_band: @target_band,
        optimal: ranked.first,
        candidates: candidates,
        ranked_candidates: ranked,
        b2o3_missing_cone6: (@target_cone == "6" && !@has_boron_source)
      )
    end

    private

    def normalize_input_entry(sample)
      raw_oxides, raw_minors = extract_sample_chemistry(sample)
      normalized = Exporters::GlazecalcMaterialSerializer.normalize_oxides(
        raw_oxides,
        minor_oxides: raw_minors
      )

      {
        sample: sample,
        oxides: normalized.slice(*CeramicOxides::KEYS),
        minor_oxides: normalized.slice(*BLENDABLE_MINOR_KEYS)
      }
    end

    def extract_sample_chemistry(sample)
      if sample.respond_to?(:stock?) && sample.stock?
        [ sample.oxides, sample.minor_oxides ]
      else
        _resolved_sample, assay = Exporters::GlazecalcMaterialSerializer.resolve_records(sample)
        minors = assay.respond_to?(:minor_oxides) ? assay.minor_oxides : nil
        [ assay.oxides, minors ]
      end
    end

    def normalize_cone(value)
      cone = value.to_s.strip
      return cone if %w[6 10].include?(cone)

      raise ArgumentError, "Unsupported target_cone: #{value.inspect}. Supported cones: 6, 10."
    end

    def normalize_surface(value)
      surface = value.to_s.strip.downcase
      return surface if %w[gloss matte].include?(surface)

      raise ArgumentError, "Unsupported surface: #{value.inspect}. Supported surfaces: gloss, matte."
    end

    def validate_samples!
      unless @samples.size.between?(2, 3)
        raise ArgumentError, "Select 2 materials (line blend) or 3 materials (triaxial blend). Received #{@samples.size}."
      end

      persisted_ids = @samples.filter_map(&:id)
      if persisted_ids.size != persisted_ids.uniq.size
        raise ArgumentError, "Duplicate materials selected. Choose 2 or 3 distinct samples."
      end
    end

    def build_line_blend_grid
      (0..100).step(LINE_BLEND_STEP).map { |pct_a| [ pct_a, 100 - pct_a ] }
    end

    def build_triaxial_grid
      grid = []
      (0..100).step(TRIAXIAL_STEP) do |pct_a|
        (0..(100 - pct_a)).step(TRIAXIAL_STEP) do |pct_b|
          pct_c = 100 - pct_a - pct_b
          grid << [ pct_a, pct_b, pct_c ]
        end
      end
      grid
    end

    def evaluate_candidate(normalized_entries, percentages)
      weights = normalized_entries.each_with_index.map do |entry, idx|
        {
          sample: entry[:sample],
          percentage: percentages[idx]
        }
      end

      raw_majors = CeramicOxides::KEYS.each_with_object({}) do |oxide, acc|
        acc[oxide] = normalized_entries.each_with_index.sum do |entry, idx|
          (percentages[idx] / 100.0) * entry[:oxides].fetch(oxide, 0.0)
        end
      end

      raw_minors = BLENDABLE_MINOR_KEYS.each_with_object({}) do |oxide, acc|
        blended_val = normalized_entries.each_with_index.sum do |entry, idx|
          (percentages[idx] / 100.0) * entry[:minor_oxides].fetch(oxide, 0.0)
        end
        acc[oxide] = blended_val if blended_val.positive?
      end

      normalized = Exporters::GlazecalcMaterialSerializer.normalize_oxides(
        raw_majors,
        minor_oxides: raw_minors
      )
      blended_majors = normalized.slice(*CeramicOxides::KEYS)
      blended_minors = normalized.slice(*BLENDABLE_MINOR_KEYS).select { |_, val| val.positive? }

      umf = Chemistry::UmfCalculator.call(blended_majors, minor_oxides: blended_minors)
      coe_report = Chemistry::CoeCalculator.call(umf, oxides: blended_majors, minor_oxides: blended_minors)
      stull_zone = self.class.classify_stull_zone(umf)
      penalty, band_checks = score_candidate(umf, stull_zone)
      fit_score = (100.0 / (1.0 + penalty)).round(1)

      Candidate.new(
        weights: weights,
        oxides: blended_majors,
        minor_oxides: blended_minors,
        umf: umf,
        coe_report: coe_report,
        penalty: penalty.round(4),
        fit_score: fit_score,
        stull_zone: stull_zone,
        band_checks: band_checks
      )
    end

    def score_candidate(umf, stull_zone)
      flux_total = umf["flux_total"].to_f
      if flux_total <= 0.0
        checks = { sio2: false, al2o3: false, si_al: false, flux: false }
        checks[:b2o3] = false if @score_b2o3
        return [ 100.0, checks ]
      end

      sio2 = umf.dig("glass_formers", "SiO2").to_f
      al2o3 = umf.dig("intermediates", "Al2O3").to_f
      si_al = umf["si_al_ratio"]&.to_f
      flux_axis = @target_band.fetch(:flux_axis)
      flux_val = flux_axis == :r2o ? umf["r2o_total"].to_f : umf["ro_total"].to_f
      flux_range = @target_band.fetch(flux_axis)

      band_checks = {
        sio2: @target_band[:sio2].cover?(sio2),
        al2o3: @target_band[:al2o3].cover?(al2o3),
        si_al: si_al.present? && @target_band[:si_al].cover?(si_al),
        flux: flux_range.cover?(flux_val)
      }

      penalty =
        (range_penalty(sio2, @target_band[:sio2]) * 1.2) +
        (range_penalty(al2o3, @target_band[:al2o3]) * 1.2) +
        (range_penalty(si_al, @target_band[:si_al]) * 1.0) +
        (range_penalty(flux_val, flux_range) * 0.8)

      if @score_b2o3
        b2o3 = umf.dig("intermediates", "B2O3").to_f
        band_checks[:b2o3] = @target_band[:b2o3].cover?(b2o3)
        penalty += range_penalty(b2o3, @target_band[:b2o3]) * 1.0
      end

      expected_zone = @surface == "gloss" ? "Gloss" : "Matte"
      penalty += 0.15 unless stull_zone == expected_zone

      [ penalty, band_checks ]
    end

    def range_penalty(value, range)
      return 10.0 if value.nil?

      width = (range.end - range.begin).to_f
      mid = (range.begin + range.end) / 2.0

      if range.cover?(value)
        0.05 * ((value - mid).abs / (width / 2.0))
      else
        excess = value < range.begin ? (range.begin - value) : (value - range.end)
        normalized = excess / width
        0.05 + normalized + (normalized**2)
      end
    end
  end
end
