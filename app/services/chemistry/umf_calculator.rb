# frozen_string_literal: true

module Chemistry
  class UmfCalculator
    MOLECULAR_WEIGHTS = {
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

    RO_OXIDES           = %w[CaO MgO].freeze
    R2O_OXIDES          = %w[Na2O K2O].freeze
    FLUX_OXIDES         = (RO_OXIDES + R2O_OXIDES).freeze
    INTERMEDIATE_OXIDES = %w[Al2O3 Fe2O3 MnO].freeze
    GLASS_FORMER_OXIDES = %w[SiO2 TiO2 P2O5].freeze
    FIRED_OXIDES        = (CeramicOxides::KEYS - ["LOI"]).freeze

    def self.call(oxides_hash)
      new(oxides_hash).call
    end

    def initialize(oxides_hash)
      @source = (oxides_hash.is_a?(Hash) ? oxides_hash : {}).transform_keys(&:to_s)
    end

    def call
      loi = numeric_value("LOI").clamp(0.0, 100.0)
      moles_per_100g = compute_moles_per_100g
      flux_moles = FLUX_OXIDES.sum { |oxide| moles_per_100g[oxide] }

      if flux_moles.positive?
        unity_moles = moles_per_100g.transform_values { |moles| moles / flux_moles }
        raw_equivalent_weight = 100.0 / flux_moles
        flux_total = FLUX_OXIDES.sum { |oxide| unity_moles[oxide] }.round(4)
        r2o_total = R2O_OXIDES.sum { |oxide| unity_moles[oxide] }.round(4)
        ro_total = RO_OXIDES.sum { |oxide| unity_moles[oxide] }.round(4)
      else
        unity_moles = moles_per_100g
        raw_equivalent_weight = 100.0
        flux_total = 0.0
        r2o_total = 0.0
        ro_total = 0.0
      end

      rounded_oxides = FIRED_OXIDES.each_with_object({}) do |oxide, acc|
        acc[oxide] = unity_moles[oxide].round(4)
      end

      {
        "fluxes"            => slice_oxides(rounded_oxides, FLUX_OXIDES),
        "intermediates"     => slice_oxides(rounded_oxides, INTERMEDIATE_OXIDES),
        "glass_formers"     => slice_oxides(rounded_oxides, GLASS_FORMER_OXIDES),
        "oxides"            => rounded_oxides,
        "flux_total"        => flux_total,
        "r2o_total"         => r2o_total,
        "ro_total"          => ro_total,
        "si_al_ratio"       => compute_si_al_ratio(moles_per_100g),
        "equivalent_weight" => raw_equivalent_weight.round(2),
        "formula_weight"    => (raw_equivalent_weight * (1.0 - loi / 100.0)).round(2)
      }
    end

    private

    def compute_moles_per_100g
      FIRED_OXIDES.each_with_object({}) do |oxide, acc|
        weight_percent = numeric_value(oxide)
        acc[oxide] = weight_percent / MOLECULAR_WEIGHTS.fetch(oxide)
      end
    end

    def compute_si_al_ratio(moles_per_100g)
      alumina_moles = moles_per_100g["Al2O3"]
      return nil unless alumina_moles.positive?

      (moles_per_100g["SiO2"] / alumina_moles).round(3)
    end

    def slice_oxides(rounded_oxides, keys)
      keys.each_with_object({}) { |oxide, acc| acc[oxide] = rounded_oxides[oxide] }
    end

    def numeric_value(key)
      raw = @source[key]
      return 0.0 if raw.nil?

      value = raw.to_f
      value.positive? ? value : 0.0
    end
  end
end
