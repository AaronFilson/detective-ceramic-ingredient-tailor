# frozen_string_literal: true

module Chemistry
  # Computes local 2-material line blends (0/100..100/0, 11 steps) and 3-material
  # triaxial simplex blends (5% step, 231 candidates), scores each candidate against
  # Cone 6 / Cone 10 Gloss & Matte Seger UMF target bands, classifies Stull zones,
  # and exports combined Materials + Recipe bundles for Glazecalc and Glaze Vault.
  class BlendRecipeBuilder
    LINE_BLEND_STEP = 10
    TRIAXIAL_STEP = 5

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
        ro: 0.55..0.80
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
        r2o: 0.15..0.40
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

    Candidate = Struct.new(
      :weights,
      :oxides,
      :umf,
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

      def si_al_ratio
        umf["si_al_ratio"]
      end

      def r2o_total
        umf["r2o_total"].to_f
      end

      def ro_total
        umf["ro_total"].to_f
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
      keyword_init: true
    ) do
      def line_blend?
        mode == :line_blend
      end

      def triaxial?
        mode == :triaxial
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
        Exporters::GlazecalcMaterialSerializer.call(sample)
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
        Exporters::GlazeVaultSerializer.call(sample).fetch("materials").first
      end

      recipe_lines = chosen.positive_weights.map do |entry|
        {
          "material" => entry[:sample].title.to_s,
          "amount" => entry[:percentage]
        }
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
        "provenance" => {
          "generator" => "Chemistry::BlendRecipeBuilder",
          "mode" => blend_result.mode.to_s,
          "target_cone" => blend_result.target_cone,
          "surface" => blend_result.surface,
          "stull_zone" => chosen.stull_zone,
          "fit_score" => chosen.fit_score,
          "umf_formula" => chosen.umf,
          "sample_ids" => blend_result.samples.map(&:id)
        }
      }
    end

    def self.build_recipe_notes(blend_result, candidate)
      mode_label = blend_result.line_blend? ? "Line Blend (10% steps)" : "Triaxial Blend (5% simplex)"
      si_al_str = candidate.si_al_ratio.present? ? format("%.2f", candidate.si_al_ratio) : "n/a"

      [
        "Generated by DCI Tailor #{mode_label} targeting #{blend_result.target_band[:label]}.",
        format(
          "Predicted UMF: SiO2 %.2f, Al2O3 %.2f, Si:Al %s, R2O %.2f, RO %.2f (%s, Fit %.1f%%).",
          candidate.sio2,
          candidate.al2o3,
          si_al_str,
          candidate.r2o_total,
          candidate.ro_total,
          candidate.stull_zone,
          candidate.fit_score
        ),
        "Batch: #{candidate.positive_weights.map { |w| "#{w[:percentage]}% #{w[:sample].title}" }.join(', ')}."
      ].join(" ")
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
      normalized_entries = @samples.map do |sample|
        _resolved_sample, assay = Exporters::GlazecalcMaterialSerializer.resolve_records(sample)
        {
          sample: sample,
          oxides: Exporters::GlazecalcMaterialSerializer.normalize_oxides(assay.oxides)
        }
      end

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
        ranked_candidates: ranked
      )
    end

    private

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

      raw_oxides = CeramicOxides::KEYS.each_with_object({}) do |oxide, acc|
        acc[oxide] = normalized_entries.each_with_index.sum do |entry, idx|
          (percentages[idx] / 100.0) * entry[:oxides].fetch(oxide, 0.0)
        end
      end

      blended_oxides = Exporters::GlazecalcMaterialSerializer.normalize_oxides(raw_oxides)
      umf = Chemistry::UmfCalculator.call(blended_oxides)
      stull_zone = self.class.classify_stull_zone(umf)
      penalty, band_checks = score_candidate(umf, stull_zone)
      fit_score = (100.0 / (1.0 + penalty)).round(1)

      Candidate.new(
        weights: weights,
        oxides: blended_oxides,
        umf: umf,
        penalty: penalty.round(4),
        fit_score: fit_score,
        stull_zone: stull_zone,
        band_checks: band_checks
      )
    end

    def score_candidate(umf, stull_zone)
      flux_total = umf["flux_total"].to_f
      if flux_total <= 0.0
        return [
          100.0,
          { sio2: false, al2o3: false, si_al: false, flux: false }
        ]
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
