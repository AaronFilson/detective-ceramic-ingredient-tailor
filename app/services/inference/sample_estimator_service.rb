# frozen_string_literal: true

module Inference
  class SampleEstimatorService
    FallbackBaseline = Struct.new(
      :oxides,
      :oxide_ranges,
      :confidence_score,
      :reasoning_log,
      keyword_init: true
    )

    CATEGORY_DEFAULTS = {
      "wild_clay" => {
        "SiO2" => 59.5, "Al2O3" => 18.5, "Fe2O3" => 5.5, "CaO" => 2.2,
        "MgO" => 1.8, "Na2O" => 1.4, "K2O" => 2.6, "TiO2" => 0.8,
        "P2O5" => 0.1, "MnO" => 0.1, "LOI" => 7.5
      },
      "crushed_rock" => {
        "SiO2" => 58.0, "Al2O3" => 16.0, "Fe2O3" => 7.0, "CaO" => 6.0,
        "MgO" => 3.5, "Na2O" => 3.8, "K2O" => 2.5, "TiO2" => 1.1,
        "P2O5" => 0.3, "MnO" => 0.15, "LOI" => 1.65
      },
      "wood_ash" => {
        "SiO2" => 12.0, "Al2O3" => 2.5, "Fe2O3" => 1.2, "CaO" => 38.0,
        "MgO" => 6.0, "Na2O" => 1.3, "K2O" => 9.0, "TiO2" => 0.2,
        "P2O5" => 3.8, "MnO" => 1.0, "LOI" => 25.0
      },
      "other" => {
        "SiO2" => 60.0, "Al2O3" => 17.0, "Fe2O3" => 5.0, "CaO" => 3.0,
        "MgO" => 2.0, "Na2O" => 2.0, "K2O" => 2.5, "TiO2" => 0.8,
        "P2O5" => 0.2, "MnO" => 0.1, "LOI" => 7.4
      }
    }.freeze

    def self.call(user_sample, field_observation: nil, baseline_estimator: nil)
      new(
        user_sample,
        field_observation: field_observation,
        baseline_estimator: baseline_estimator
      ).call
    end

    def initialize(user_sample, field_observation: nil, baseline_estimator: nil)
      raise ArgumentError, "user_sample is required" if user_sample.nil?

      @user_sample = user_sample
      @field_observation = field_observation
      @baseline_estimator = baseline_estimator
    end

    def call
      baseline = resolve_baseline
      observation = @field_observation || @user_sample.latest_field_observation

      base_log = Array(baseline.reasoning_log).map(&:to_s)
      base_confidence = baseline.confidence_score.to_f

      if observation
        modified = Inference::ObservationModifierService.call(baseline.oxide_ranges, observation)
        final_oxides = modified.oxides
        final_ranges = modified.oxide_ranges
        final_umf = modified.umf_formula
        combined_log = base_log + Array(modified.reasoning_log).map(&:to_s)
        final_confidence = (base_confidence + modified.confidence_adjustment.to_f).clamp(0.0, 1.0).round(3)
      else
        raw_oxides = baseline.oxides.is_a?(Hash) && !baseline.oxides.empty? ? baseline.oxides : extract_medians(baseline.oxide_ranges)
        final_oxides = Inference::ObservationModifierService.normalize_exact_oxides(raw_oxides.transform_keys(&:to_s))
        final_ranges = baseline.oxide_ranges || {}
        final_umf = Chemistry::UmfCalculator.call(final_oxides)
        combined_log = base_log
        final_confidence = base_confidence.clamp(0.0, 1.0).round(3)
      end

      persist_assay_result(
        oxides: final_oxides,
        oxide_ranges: final_ranges,
        umf_formula: final_umf,
        confidence_score: final_confidence,
        reasoning_log: combined_log
      )
    end

    private

    def resolve_baseline
      estimator = if @baseline_estimator
        @baseline_estimator
      elsif defined?(Inference::BaselineEstimatorService)
        Inference::BaselineEstimatorService
      end

      return estimator.call(@user_sample) if estimator

      fallback_category_baseline
    end

    def persist_assay_result(attributes)
      assay_result = @user_sample.assay_results
        .spatial_heuristic_estimate
        .order(created_at: :desc, id: :desc)
        .first || @user_sample.assay_results.build(source_type: :spatial_heuristic_estimate)

      assay_result.assign_attributes(attributes)
      assay_result.save!
      assay_result
    end

    def extract_medians(oxide_ranges)
      return {} unless oxide_ranges.is_a?(Hash)

      oxide_ranges.transform_keys(&:to_s).transform_values do |entry|
        entry.is_a?(Hash) ? (entry["median"] || entry[:median] || 0.0).to_f : entry.to_f
      end
    end

    def fallback_category_baseline
      category = @user_sample.material_category.to_s
      medians = CATEGORY_DEFAULTS.fetch(category, CATEGORY_DEFAULTS["other"])
      oxides = Inference::ObservationModifierService.normalize_exact_oxides(medians)

      ranges = oxides.transform_values do |med|
        spread = [med * 0.25, 0.5].max
        r_min = [med - spread, 0.0].max.round(2)
        r_max = [med + spread, 100.0].min.round(2)
        r_q1  = ((r_min + med) / 2.0).round(2)
        r_q3  = ((med + r_max) / 2.0).round(2)
        {
          "min"    => r_min,
          "q1"     => r_q1,
          "median" => med,
          "q3"     => r_q3,
          "max"    => r_max,
          "iqr"    => (r_q3 - r_q1).round(2)
        }
      end

      FallbackBaseline.new(
        oxides: oxides,
        oxide_ranges: ranges,
        confidence_score: 0.25,
        reasoning_log: ["Applied default #{category.tr('_', ' ')} ceramic chemistry baseline (spatial estimator unavailable)."]
      )
    end
  end
end
