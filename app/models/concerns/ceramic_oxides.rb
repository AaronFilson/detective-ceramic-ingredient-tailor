# frozen_string_literal: true

module CeramicOxides
  KEYS = %w[
    SiO2
    Al2O3
    Fe2O3
    CaO
    MgO
    Na2O
    K2O
    TiO2
    P2O5
    MnO
    LOI
  ].freeze

  # Stoichiometric gravimetric conversion factors from elemental weight
  # to canonical ceramic oxide weight (IUPAC standard atomic weights).
  ELEMENT_TO_OXIDE_FACTORS = {
    "Si" => { oxide: "SiO2",  factor: 2.1393 },
    "Al" => { oxide: "Al2O3", factor: 1.8895 },
    "Fe" => { oxide: "Fe2O3", factor: 1.4297 },
    "Ca" => { oxide: "CaO",   factor: 1.3992 },
    "Mg" => { oxide: "MgO",   factor: 1.6583 },
    "Na" => { oxide: "Na2O",  factor: 1.3480 },
    "K"  => { oxide: "K2O",   factor: 1.2046 },
    "Ti" => { oxide: "TiO2",  factor: 1.6685 },
    "P"  => { oxide: "P2O5",  factor: 2.2914 },
    "Mn" => { oxide: "MnO",   factor: 1.2912 }
  }.freeze

  # Conversion factor from ferrous oxide (FeO) to ferric oxide (Fe2O3).
  FEO_TO_FE2O3_FACTOR = 1.1113

  module_function

  # Normalizes a hash of oxide weight percentages (including LOI) so that
  # all canonical KEYS are present and sum to 100.0% (within +-0.001%).
  # Returns nil when total is not positive.
  def normalize(raw_oxides = nil, precision: 4, **keyword_oxides)
    combined = (raw_oxides.is_a?(Hash) ? raw_oxides : {}).merge(keyword_oxides)
    source = combined.transform_keys(&:to_s)
    values = KEYS.each_with_object({}) do |key, acc|
      val = source[key]
      num = val.nil? ? 0.0 : val.to_f
      acc[key] = num.positive? ? num : 0.0
    end

    total = values.values.sum
    return nil unless total.positive?

    scale = 100.0 / total
    values.transform_values { |v| (v * scale).round(precision) }
  end
end
