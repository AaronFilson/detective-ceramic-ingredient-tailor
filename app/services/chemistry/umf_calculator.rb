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

    ALL_MOLECULAR_WEIGHTS = CeramicOxides::ALL_OXIDE_MOLAR_WEIGHTS

    RO_OXIDES           = %w[CaO MgO MnO].freeze
    R2O_OXIDES          = %w[Na2O K2O].freeze
    FLUX_OXIDES         = (RO_OXIDES + R2O_OXIDES).freeze
    INTERMEDIATE_OXIDES = %w[Al2O3 Fe2O3].freeze
    GLASS_FORMER_OXIDES = %w[SiO2 TiO2 P2O5].freeze
    FIRED_OXIDES        = (CeramicOxides::KEYS - [ "LOI" ]).freeze

    # Non-volatile minor ceramic oxides aligned with glazecalc (excludes SO3 and F volatiles).
    MINOR_FIRED_OXIDES        = (ALL_MOLECULAR_WEIGHTS.keys - FIRED_OXIDES).freeze
    ALL_FIRED_OXIDES          = (FIRED_OXIDES + MINOR_FIRED_OXIDES).freeze
    MINOR_R2O_OXIDES          = MINOR_FIRED_OXIDES.select { |ox| CeramicOxides::ALL_OXIDE_GROUPS[ox] == "R2O" }.freeze
    MINOR_RO_OXIDES           = MINOR_FIRED_OXIDES.select { |ox| CeramicOxides::ALL_OXIDE_GROUPS[ox] == "RO" }.freeze
    MINOR_FLUX_OXIDES         = (MINOR_RO_OXIDES + MINOR_R2O_OXIDES).freeze
    MINOR_INTERMEDIATE_OXIDES = MINOR_FIRED_OXIDES.select { |ox| CeramicOxides::ALL_OXIDE_GROUPS[ox] == "R2O3" }.freeze
    MINOR_GLASS_FORMER_OXIDES = MINOR_FIRED_OXIDES.select { |ox| CeramicOxides::ALL_OXIDE_GROUPS[ox] == "RO2" }.freeze

    ALL_R2O_OXIDES          = (R2O_OXIDES + MINOR_R2O_OXIDES).freeze
    ALL_RO_OXIDES           = (RO_OXIDES + MINOR_RO_OXIDES).freeze
    ALL_FLUX_OXIDES         = (FLUX_OXIDES + MINOR_FLUX_OXIDES).freeze
    ALL_INTERMEDIATE_OXIDES = (INTERMEDIATE_OXIDES + MINOR_INTERMEDIATE_OXIDES).freeze
    ALL_GLASS_FORMER_OXIDES = (GLASS_FORMER_OXIDES + MINOR_GLASS_FORMER_OXIDES).freeze

    def self.call(oxides_hash = nil, minor_oxides: nil, **keyword_oxides)
      combined = (oxides_hash.is_a?(Hash) ? oxides_hash : {}).merge(keyword_oxides)
      new(combined, minor_oxides: minor_oxides).call
    end

    def initialize(oxides_hash = nil, minor_oxides: nil, **keyword_oxides)
      base = (oxides_hash.is_a?(Hash) ? oxides_hash : {}).merge(keyword_oxides).transform_keys(&:to_s)
      minors = (minor_oxides.is_a?(Hash) ? minor_oxides : {}).transform_keys(&:to_s)
      @source = base.merge(minors.slice(*MINOR_FIRED_OXIDES))
    end

    def call
      loi = numeric_value("LOI").clamp(0.0, 100.0)
      active_minor_oxides = MINOR_FIRED_OXIDES.select { |oxide| numeric_value(oxide).positive? }
      active_fired_oxides = FIRED_OXIDES + active_minor_oxides

      active_ro_oxides = RO_OXIDES + (active_minor_oxides & MINOR_RO_OXIDES)
      active_r2o_oxides = R2O_OXIDES + (active_minor_oxides & MINOR_R2O_OXIDES)
      active_flux_oxides = active_ro_oxides + active_r2o_oxides
      active_intermediate_oxides = INTERMEDIATE_OXIDES + (active_minor_oxides & MINOR_INTERMEDIATE_OXIDES)
      active_glass_former_oxides = GLASS_FORMER_OXIDES + (active_minor_oxides & MINOR_GLASS_FORMER_OXIDES)

      moles_per_100g = compute_moles_per_100g(active_fired_oxides)
      flux_moles = active_flux_oxides.sum { |oxide| moles_per_100g[oxide] }

      if flux_moles.positive?
        unity_moles = moles_per_100g.transform_values { |moles| moles / flux_moles }
        raw_equivalent_weight = 100.0 / flux_moles
        flux_total = active_flux_oxides.sum { |oxide| unity_moles[oxide] }.round(4)
        r2o_total = active_r2o_oxides.sum { |oxide| unity_moles[oxide] }.round(4)
        ro_total = active_ro_oxides.sum { |oxide| unity_moles[oxide] }.round(4)
      else
        unity_moles = moles_per_100g
        raw_equivalent_weight = 100.0
        flux_total = 0.0
        r2o_total = 0.0
        ro_total = 0.0
      end

      rounded_oxides = active_fired_oxides.each_with_object({}) do |oxide, acc|
        acc[oxide] = unity_moles[oxide].round(4)
      end

      {
        "fluxes"            => slice_oxides(rounded_oxides, active_flux_oxides),
        "intermediates"     => slice_oxides(rounded_oxides, active_intermediate_oxides),
        "glass_formers"     => slice_oxides(rounded_oxides, active_glass_former_oxides),
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

    def compute_moles_per_100g(fired_oxides)
      fired_oxides.each_with_object({}) do |oxide, acc|
        weight_percent = numeric_value(oxide)
        acc[oxide] = weight_percent / ALL_MOLECULAR_WEIGHTS.fetch(oxide)
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
