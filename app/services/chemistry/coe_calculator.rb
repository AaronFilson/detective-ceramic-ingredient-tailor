# frozen_string_literal: true

module Chemistry
  # Predicts linear glaze thermal expansion (COE) and crazing/shivering fit risk
  # using ceramic Appen / English-Turner fired weight-percent oxide factors.
  #
  # Basis & Units:
  #   - Inputs (UMF formula hash OR raw/normalized major + minor oxide wt% hashes)
  #     are converted onto a 100% volatile-free fired oxide weight-% basis
  #     (excluding LOI, SO3, and F).
  #   - Each oxide's fired wt% is multiplied by its Appen / English-Turner linear
  #     expansion factor (cubical factor / 30) to yield linear COE on the classic
  #     studio ceramic scale (reported in units of x10^-7 /°C, where balanced
  #     stoneware glazes fall around 5.5-7.4, high-alkali glazes exceed 8.0-8.4
  #     with high crazing risk, and high-SiO2/B2O3/Li2O/MgO glazes drop below 5.5).
  class CoeCalculator
    # Fired weight-% linear expansion factors (Appen / English-Turner / Hall
    # ceramic glaze basis). Multiply fired wt% (0..100) by factor and sum.
    OXIDE_FACTORS = {
      "Na2O"  => 0.432, # English-Turner 12.96 / 30 (strongest crazing driver)
      "K2O"   => 0.390, # English-Turner 11.70 / 30
      "Cr2O3" => 0.170, # Mayer-Havas 5.10 / 30
      "CaO"   => 0.163, # English-Turner 4.89 / 30
      "SrO"   => 0.155, # Appen alkaline-earth interpolation (CaO-BaO)
      "CoO"   => 0.147, # Mayer-Havas 4.40 / 30
      "BaO"   => 0.140, # English-Turner 4.20 / 30
      "TiO2"  => 0.137, # English-Turner 4.10 / 30
      "Fe2O3" => 0.133, # Hall / Mayer-Havas 4.00 / 30
      "NiO"   => 0.133, # Mayer-Havas 4.00 / 30
      "CeO2"  => 0.090,
      "Pr2O3" => 0.090,
      "V2O5"  => 0.080,
      "MnO"   => 0.073, # Mayer-Havas 2.20 / 30
      "CuO"   => 0.073, # Mayer-Havas 2.20 / 30
      "ZnO"   => 0.070, # English-Turner 2.10 / 30
      "ZrO2"  => 0.070, # English-Turner 2.10 / 30
      "Li2O"  => 0.067, # English-Turner ceramic glaze 2.00 / 30 (low-expansion R2O)
      "P2O5"  => 0.067, # Winkelmann-Schott 2.00 / 30
      "SnO2"  => 0.067, # Mayer-Havas 2.00 / 30
      "Al2O3" => 0.050, # Ceramic glaze intermediate network stabilizer
      "MgO"   => 0.045, # English-Turner 1.35 / 30 (low-expansion RO)
      "SiO2"  => 0.020, # Silicate glass network former
      "B2O3"  => 0.005  # Borate low-expansion glass former
    }.freeze

    VOLATILE_KEYS = %w[LOI SO3 F].freeze
    SHIVERING_MAX = 5.5
    BALANCED_MAX = 7.4
    MODERATE_CRAZING_MAX = 8.4

    Result = Struct.new(
      :coe,
      :risk_level,
      :risk_label,
      :badge_classes,
      :guidance,
      :top_contributors,
      keyword_init: true
    )

    def self.call(umf_or_oxides = nil, oxides: nil, minor_oxides: nil)
      new(umf_or_oxides, oxides: oxides, minor_oxides: minor_oxides).call
    end

    def initialize(umf_or_oxides = nil, oxides: nil, minor_oxides: nil)
      @umf_or_oxides = umf_or_oxides
      @explicit_oxides = oxides
      @explicit_minor_oxides = minor_oxides
    end

    def call
      fired_wt_pct = resolve_fired_weight_percents
      if fired_wt_pct.empty?
        return build_result(coe: 0.0, contributors: [])
      end

      contributions = fired_wt_pct.filter_map do |oxide, pct|
        factor = OXIDE_FACTORS[oxide]
        next unless factor && pct.positive?

        contribution = pct * factor
        { oxide: oxide, contribution: contribution }
      end

      total_coe = contributions.sum { |entry| entry[:contribution] }.round(2)
      top_contributors = contributions
        .sort_by { |entry| -entry[:contribution] }
        .first(3)
        .map { |entry| { oxide: entry[:oxide], contribution: entry[:contribution].round(2) } }

      build_result(coe: total_coe, contributors: top_contributors)
    end

    private

    def resolve_fired_weight_percents
      raw = if @explicit_oxides.is_a?(Hash) && @explicit_oxides.any?
        merge_oxide_hashes(@explicit_oxides, @explicit_minor_oxides)
      elsif umf_hash?(@umf_or_oxides)
        umf_to_fired_weights(@umf_or_oxides)
      elsif @umf_or_oxides.is_a?(Hash) && @umf_or_oxides.any?
        merge_oxide_hashes(@umf_or_oxides, @explicit_minor_oxides)
      else
        {}
      end

      normalize_fired_weights(raw)
    end

    def umf_hash?(input)
      return false unless input.is_a?(Hash)

      string_keys = input.transform_keys(&:to_s)
      string_keys["oxides"].is_a?(Hash) &&
        (string_keys.key?("flux_total") || string_keys["fluxes"].is_a?(Hash))
    end

    def umf_to_fired_weights(umf)
      umf_oxides = umf.transform_keys(&:to_s).fetch("oxides", {}).transform_keys(&:to_s)
      umf_oxides.each_with_object({}) do |(oxide, moles), acc|
        mw = CeramicOxides::ALL_OXIDE_MOLAR_WEIGHTS[oxide]
        val = positive_float(moles)
        next unless mw && val.positive?

        acc[oxide] = val * mw
      end
    end

    def merge_oxide_hashes(majors, minors)
      base = majors.transform_keys(&:to_s)
      extra = minors.is_a?(Hash) ? minors.transform_keys(&:to_s) : {}
      base.merge(extra)
    end

    def normalize_fired_weights(raw)
      fired = raw.each_with_object({}) do |(oxide, val), acc|
        key = oxide.to_s
        next if VOLATILE_KEYS.include?(key)
        next unless OXIDE_FACTORS.key?(key)

        num = positive_float(val)
        acc[key] = num if num.positive?
      end

      total = fired.values.sum
      return {} unless total.positive?

      scale = 100.0 / total
      fired.transform_values { |val| val * scale }
    end

    def build_result(coe:, contributors:)
      risk_level, risk_label, badge_classes, guidance = classify_risk(coe)

      Result.new(
        coe: coe,
        risk_level: risk_level,
        risk_label: risk_label,
        badge_classes: badge_classes,
        guidance: guidance,
        top_contributors: contributors
      )
    end

    def classify_risk(coe)
      if coe < SHIVERING_MAX
        [
          :shivering_risk,
          "Shivering Watch",
          "bg-sky-100 text-sky-900 border-sky-300",
          "Low predicted thermal expansion (< 5.5). Watch for shivering on sharp rims or high-quartz clay bodies; add a modest feldspar or whiting increase if edges flake."
        ]
      elsif coe <= BALANCED_MAX
        [
          :balanced_fit,
          "Balanced Fit",
          "bg-emerald-50 text-emerald-900 border-emerald-200",
          "Predicted expansion falls in the balanced stoneware fit window (5.5-7.4). Strong starting point for craze-free functional ware on typical stoneware bodies."
        ]
      elsif coe <= MODERATE_CRAZING_MAX
        [
          :moderate_crazing,
          "Moderate Crazing",
          "bg-amber-100 text-amber-950 border-amber-300",
          "Moderately elevated thermal expansion (7.4-8.4) may craze on lower-expansion stoneware. Adding silica, talc/dolomite, or spodumene helps tighten glaze fit."
        ]
      else
        [
          :high_crazing,
          "High Crazing Risk",
          "bg-red-100 text-red-900 border-red-300",
          "High predicted thermal expansion (> 8.4), usually driven by Na2O/K2O alkalis. Likely to craze; reduce feldspar/nepheline syenite and boost SiO2, B2O3, MgO, or Li2O."
        ]
      end
    end

    def positive_float(value)
      return 0.0 if value.nil?

      num = Float(value)
      return 0.0 if num.nan? || num.infinite? || num <= 0.0

      num
    rescue ArgumentError, TypeError
      0.0
    end
  end
end
