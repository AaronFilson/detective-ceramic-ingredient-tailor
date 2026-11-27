# frozen_string_literal: true

module Exporters
  # Serializes an AssayResult (or UserSample via its latest AssayResult) into
  # a glazecalc-compatible Material JSON payload with stoichiometric unity
  # values, exact 100.00% oxide+LOI normalization, UMF breakdown, and provenance.
  class GlazecalcMaterialSerializer
    APPLICATION_NAME = "detective-ceramic-ingredient-tailor"

    MOLAR_MASSES = {
      "SiO2"  => 60.08,
      "Al2O3" => 101.96,
      "Fe2O3" => 159.69,
      "CaO"   => 56.08,
      "MgO"   => 40.30,
      "Na2O"  => 61.98,
      "K2O"   => 94.20,
      "TiO2"  => 79.87,
      "P2O5"  => 141.94,
      "MnO"   => 70.94
    }.freeze

    FIRED_OXIDES = (CeramicOxides::KEYS - [ "LOI" ]).freeze
    FLUX_OXIDES = %w[CaO MgO Na2O K2O].freeze
    R2O_OXIDES = %w[Na2O K2O].freeze
    RO_OXIDES = %w[CaO MgO].freeze
    INTERMEDIATE_OXIDES = %w[Al2O3 Fe2O3 MnO].freeze
    GLASS_FORMER_OXIDES = %w[SiO2 TiO2 P2O5].freeze

    def self.call(assay_result_or_sample)
      new(assay_result_or_sample).call
    end

    # Resolves either an AssayResult or a UserSample into [user_sample, assay_result].
    def self.resolve_records(assay_result_or_sample)
      case assay_result_or_sample
      when AssayResult
        sample = assay_result_or_sample.user_sample
        raise ArgumentError, "AssayResult must belong to a UserSample" if sample.nil?

        [ sample, assay_result_or_sample ]
      when UserSample
        assay = assay_result_or_sample.latest_assay_result
        raise ArgumentError, "UserSample ##{assay_result_or_sample.id || 'unsaved'} has no AssayResult" if assay.nil?

        [ assay_result_or_sample, assay ]
      else
        raise ArgumentError, "Expected AssayResult or UserSample, got #{assay_result_or_sample.class}"
      end
    end

    # Normalizes an oxide hash so that all canonical CeramicOxides::KEYS sum to
    # exact 100.00% (at 2 decimal places) with 0.0 <= LOI < 100.0 and any 0.01
    # rounding residual applied to the largest fired oxide.
    def self.normalize_oxides(raw_oxides)
      raise ArgumentError, "AssayResult oxides must be a non-empty Hash" unless raw_oxides.is_a?(Hash) && raw_oxides.any?

      source = raw_oxides.transform_keys(&:to_s)
      sanitized = CeramicOxides::KEYS.each_with_object({}) do |key, acc|
        acc[key] = parse_non_negative_float(source[key])
      end

      fired_total = FIRED_OXIDES.sum { |key| sanitized[key] }
      total = fired_total + sanitized["LOI"]
      raise ArgumentError, "AssayResult must contain positive fired oxide weight percentages" unless fired_total.positive? && total.positive?

      scale = 100.0 / total
      scaled = sanitized.transform_values { |val| val * scale }
      hundredths = scaled.transform_values { |val| (val * 100.0).round }

      # Ensure LOI strictly satisfies 0.0 <= loi < 100.0 (max 99.99%).
      if hundredths["LOI"] >= 10_000
        hundredths["LOI"] = 9_999
      end

      largest_fired = FIRED_OXIDES.max_by { |key| scaled[key] }
      residual = 10_000 - hundredths.values.sum

      if residual != 0
        if hundredths[largest_fired] + residual >= 1
          hundredths[largest_fired] += residual
        else
          apply_residual_safely!(hundredths, residual)
        end
      end

      # Guarantee at least 0.01% fired oxide remains after rounding.
      if FIRED_OXIDES.sum { |key| hundredths[key] } <= 0
        hundredths[largest_fired] = 1
        hundredths["LOI"] = 9_999
      end

      hundredths.transform_values { |val| (val / 100.0).round(2) }
    end

    # Computes Unity Molecular Formula using Chemistry::UmfCalculator when
    # available, falling back to an identical stoichiometric calculation.
    def self.compute_umf(normalized_oxides)
      if defined?(Chemistry::UmfCalculator)
        Chemistry::UmfCalculator.call(normalized_oxides)
      else
        compute_umf_inline(normalized_oxides)
      end
    end

    def self.compute_umf_inline(normalized_oxides)
      loi = normalized_oxides.fetch("LOI", 0.0).to_f
      moles_per_gram = FIRED_OXIDES.each_with_object({}) do |oxide, acc|
        wt_pct = normalized_oxides.fetch(oxide, 0.0).to_f
        acc[oxide] = (wt_pct / 100.0) / MOLAR_MASSES.fetch(oxide)
      end

      flux_per_gram = FLUX_OXIDES.sum { |oxide| moles_per_gram[oxide] }
      r2o_per_gram = R2O_OXIDES.sum { |oxide| moles_per_gram[oxide] }
      ro_per_gram = RO_OXIDES.sum { |oxide| moles_per_gram[oxide] }

      raw_equivalent = flux_per_gram.positive? ? (1.0 / flux_per_gram) : 100.0
      equivalent_weight = raw_equivalent.round(2)
      formula_weight = (equivalent_weight * (1.0 - loi / 100.0)).round(2)

      unity_oxides = FIRED_OXIDES.each_with_object({}) do |oxide, acc|
        acc[oxide] = (moles_per_gram[oxide] * raw_equivalent).round(4)
      end

      si_moles = moles_per_gram["SiO2"]
      al_moles = moles_per_gram["Al2O3"]
      si_al_ratio = al_moles.positive? ? (si_moles / al_moles).round(3) : nil

      {
        "fluxes" => FLUX_OXIDES.each_with_object({}) { |ox, acc| acc[ox] = unity_oxides[ox] },
        "intermediates" => INTERMEDIATE_OXIDES.each_with_object({}) { |ox, acc| acc[ox] = unity_oxides[ox] },
        "glass_formers" => GLASS_FORMER_OXIDES.each_with_object({}) { |ox, acc| acc[ox] = unity_oxides[ox] },
        "oxides" => unity_oxides,
        "flux_total" => flux_per_gram.positive? ? 1.0 : 0.0,
        "r2o_total" => (r2o_per_gram * raw_equivalent).round(4),
        "ro_total" => (ro_per_gram * raw_equivalent).round(4),
        "si_al_ratio" => si_al_ratio,
        "equivalent_weight" => equivalent_weight,
        "formula_weight" => formula_weight
      }
    end

    def self.format_reasoning_entry(entry)
      text = case entry
      when Hash
        entry["message"] || entry[:message] || entry["detail"] || entry[:detail] ||
          entry.map { |k, v| "#{k}: #{v}" }.join(", ")
      else
        entry.to_s
      end
      text.strip
    end

    def self.field_observation_summary(observation)
      return nil if observation.nil?

      parts = []
      parts << "vinegar fizz: #{observation.vinegar_fizz.tr('_', ' ')}" if observation.vinegar_fizz.present?
      parts << "slaking: #{observation.slaking_behavior.tr('_', ' ')}" if observation.slaking_behavior.present?
      parts << "plasticity: #{observation.plasticity.tr('_', ' ')}" if observation.plasticity.present?
      parts << "raw color: #{observation.raw_color.strip}" if observation.raw_color.present?
      parts << "fired cone: #{observation.fired_cone.strip}" if observation.fired_cone.present?
      parts << "fired color: #{observation.fired_color.strip}" if observation.fired_color.present?
      parts << "melt state: #{observation.melt_state.tr('_', ' ')}" if observation.melt_state.present?
      if observation.shrinkage_percent.present?
        shrinkage = format("%.2f", observation.shrinkage_percent.to_f).sub(/\.?0+\z/, "")
        parts << "shrinkage: #{shrinkage}%"
      end

      return nil if parts.empty?

      "Field observations: #{parts.join('; ')}"
    end

    def self.parse_non_negative_float(value)
      return 0.0 if value.nil?

      num = Float(value)
      return 0.0 if num.nan? || num.infinite? || num <= 0.0

      num
    rescue ArgumentError, TypeError
      0.0
    end
    private_class_method :parse_non_negative_float

    def self.apply_residual_safely!(hundredths, residual)
      step = residual.positive? ? 1 : -1
      remaining = residual.abs

      ordered_keys = FIRED_OXIDES.sort_by { |key| -hundredths[key] }
      ordered_keys.each do |key|
        break if remaining.zero?

        if step.positive?
          hundredths[key] += remaining
          remaining = 0
        elsif hundredths[key] > 1
          deduct = [ remaining, hundredths[key] - 1 ].min
          hundredths[key] -= deduct
          remaining -= deduct
        end
      end
    end
    private_class_method :apply_residual_safely!

    def initialize(assay_result_or_sample)
      @sample, @assay_result = self.class.resolve_records(assay_result_or_sample)
    end

    def call
      normalized = self.class.normalize_oxides(@assay_result.oxides)
      loi = normalized.fetch("LOI")

      moles_per_gram = FIRED_OXIDES.each_with_object({}) do |oxide, acc|
        acc[oxide] = (normalized[oxide] / 100.0) / MOLAR_MASSES.fetch(oxide)
      end

      flux_per_gram = FLUX_OXIDES.sum { |oxide| moles_per_gram[oxide] }
      raw_equivalent = flux_per_gram.positive? ? (1.0 / flux_per_gram) : 100.0
      equivalent = raw_equivalent.round(2)
      formulaweight = (equivalent * (1.0 - loi / 100.0)).round(2)

      fields = FIRED_OXIDES.filter_map do |oxide|
        pct = normalized[oxide]
        next unless pct.positive?

        {
          "name" => oxide,
          "amount" => format("%.2f", pct),
          "amountUnity" => (moles_per_gram[oxide] * raw_equivalent).round(4)
        }
      end

      oxide_analysis = FIRED_OXIDES.each_with_object({}) do |oxide, acc|
        pct = normalized[oxide]
        acc[oxide] = pct if pct.positive?
      end

      {
        "name" => @sample.title.to_s,
        "fields" => fields,
        "percentmole" => "percent",
        "loi" => loi,
        "molecularweight" => 100.0,
        "equivalent" => equivalent,
        "formulaweight" => formulaweight,
        "rawformula" => build_rawformula(normalized, loi),
        "oxideAnalysis" => oxide_analysis,
        "oxides" => normalized,
        "umf" => self.class.compute_umf(normalized),
        "source" => build_source,
        "notes" => build_notes,
        "relatedTo" => build_related_to
      }
    end

    private

    def build_rawformula(normalized, loi)
      entries = FIRED_OXIDES.filter_map do |oxide|
        pct = normalized[oxide]
        next unless pct.positive?

        "#{oxide} #{format('%.2f', pct)}%"
      end
      entries << "LOI #{format('%.2f', loi)}%" if loi.positive?
      entries.join(", ")
    end

    def build_source
      unit = @sample.geologic_unit
      {
        "kind" => @assay_result.source_type,
        "application" => APPLICATION_NAME,
        "sample_id" => @sample.id,
        "assay_result_id" => @assay_result.id,
        "confidence_score" => @assay_result.confidence_score&.to_f,
        "coordinates" => {
          "lat" => @sample.latitude&.to_f,
          "lng" => @sample.longitude&.to_f
        },
        "geologic_unit" => unit ? {
          "macrostrat_id" => unit.macrostrat_id,
          "name" => unit.name,
          "strat_name" => unit.strat_name,
          "age" => unit.age,
          "lithology" => unit.lithology_terms
        } : nil,
        "generated_at" => Time.current.utc.iso8601
      }
    end

    def build_notes
      lines = []
      lines << @sample.notes.strip if @sample.notes.present?

      if (provenance = geologic_provenance_note)
        lines << provenance
      end

      latest_obs = resolve_latest_observation
      if (obs_summary = self.class.field_observation_summary(latest_obs))
        lines << obs_summary
      end

      Array(@assay_result.reasoning_log).each do |entry|
        formatted = self.class.format_reasoning_entry(entry)
        lines << formatted unless formatted.empty?
      end

      lines.uniq
    end

    def geologic_provenance_note
      parts = []
      if (unit = @sample.geologic_unit)
        unit_label = [ unit.name, unit.strat_name ].compact.map(&:strip).reject(&:empty?).uniq.join(" / ")
        unit_desc = unit_label.empty? ? "Macrostrat unit ##{unit.macrostrat_id}" : "#{unit_label} (Macrostrat ##{unit.macrostrat_id})"
        unit_desc = "#{unit_desc}, #{unit.age}" if unit.age.present?
        terms = unit.lithology_terms
        unit_desc = "#{unit_desc} [#{terms.join(', ')}]" if terms.any?
        parts << "Geologic unit: #{unit_desc}"
      end

      if @sample.latitude.present? && @sample.longitude.present?
        parts << format("Coordinates: %.4f, %.4f", @sample.latitude.to_f, @sample.longitude.to_f)
      end

      return nil if parts.empty?

      parts.join(" | ")
    end

    def build_related_to
      terms = []
      if @sample.material_category.present?
        terms << @sample.material_category.to_s.tr("_", " ")
      end

      if (unit = @sample.geologic_unit)
        terms << unit.name if unit.name.present?
        terms << unit.strat_name if unit.strat_name.present?
        terms.concat(unit.lithology_terms)
      end

      seen = {}
      terms.each_with_object([]) do |term, acc|
        cleaned = term.to_s.strip
        next if cleaned.empty?

        key = cleaned.downcase
        next if seen[key]

        seen[key] = true
        acc << cleaned
      end
    end

    def resolve_latest_observation
      if @sample.field_observations.loaded?
        @sample.field_observations.max_by { |obs| [ obs.created_at || Time.at(0), obs.id || 0 ] }
      else
        @sample.latest_field_observation
      end
    end
  end
end
