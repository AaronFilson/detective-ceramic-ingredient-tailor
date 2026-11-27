# frozen_string_literal: true

module CeramicOxides
  # Canonical 11 major ceramic oxides + LOI (normalized to 100.0%).
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

  # Extended minor/colorant/opacifier/flux oxides aligned with glazecalc/lib/catalog/oxides.ts.
  MINOR_KEYS = %w[
    Li2O
    B2O3
    SrO
    BaO
    ZnO
    ZrO2
    SnO2
    Cr2O3
    CuO
    CoO
    NiO
    V2O5
    CeO2
    Pr2O3
    SO3
    F
  ].freeze

  # Pathfinder, heavy-metal, and hazard trace elements tracked in ppm.
  TRACE_ELEMENT_KEYS = %w[
    Li B S F Cr Co Ni Cu Zn As Rb Sr Zr Nb Sn Cs Ba Ce Pr Ta Pb Cd U Th V
  ].freeze

  # Stoichiometric gravimetric conversion factors from elemental weight
  # to canonical major ceramic oxide weight (IUPAC standard atomic weights).
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

  # Stoichiometric gravimetric conversion factors for minor/glaze oxides.
  MINOR_ELEMENT_TO_OXIDE_FACTORS = {
    "Li" => { oxide: "Li2O",  factor: 2.1527 },
    "B"  => { oxide: "B2O3",  factor: 3.2199 },
    "Sr" => { oxide: "SrO",   factor: 1.1826 },
    "Ba" => { oxide: "BaO",   factor: 1.1165 },
    "Zn" => { oxide: "ZnO",   factor: 1.2447 },
    "Zr" => { oxide: "ZrO2",  factor: 1.3508 },
    "Sn" => { oxide: "SnO2",  factor: 1.2696 },
    "Cr" => { oxide: "Cr2O3", factor: 1.4615 },
    "Cu" => { oxide: "CuO",   factor: 1.2518 },
    "Co" => { oxide: "CoO",   factor: 1.2715 },
    "Ni" => { oxide: "NiO",   factor: 1.2725 },
    "V"  => { oxide: "V2O5",  factor: 1.7852 },
    "Ce" => { oxide: "CeO2",  factor: 1.2284 },
    "Pr" => { oxide: "Pr2O3", factor: 1.1703 },
    "S"  => { oxide: "SO3",   factor: 2.4972 },
    "F"  => { oxide: "F",     factor: 1.0000 }
  }.freeze

  # Full molar masses (g/mol) aligned with glazecalc/lib/catalog/oxides.ts.
  ALL_OXIDE_MOLAR_WEIGHTS = {
    "SiO2"  => 60.08,
    "Al2O3" => 101.96,
    "Fe2O3" => 159.69,
    "CaO"   => 56.08,
    "MgO"   => 40.30,
    "Na2O"  => 61.98,
    "K2O"   => 94.20,
    "TiO2"  => 79.87,
    "P2O5"  => 141.94,
    "MnO"   => 70.94,
    "Li2O"  => 29.88,
    "B2O3"  => 69.62,
    "SrO"   => 103.62,
    "BaO"   => 153.33,
    "ZnO"   => 81.38,
    "ZrO2"  => 123.22,
    "SnO2"  => 150.71,
    "Cr2O3" => 151.99,
    "CuO"   => 79.55,
    "CoO"   => 74.93,
    "NiO"   => 74.69,
    "V2O5"  => 181.88,
    "CeO2"  => 172.11,
    "Pr2O3" => 329.81
  }.freeze

  # Seger UMF groups aligned 1-to-1 with glazecalc/lib/catalog/oxides.ts.
  ALL_OXIDE_GROUPS = {
    "Li2O"  => "R2O",
    "Na2O"  => "R2O",
    "K2O"   => "R2O",
    "MgO"   => "RO",
    "CaO"   => "RO",
    "SrO"   => "RO",
    "BaO"   => "RO",
    "ZnO"   => "RO",
    "MnO"   => "RO",
    "CuO"   => "RO",
    "CoO"   => "RO",
    "NiO"   => "RO",
    "Al2O3" => "R2O3",
    "B2O3"  => "R2O3",
    "Fe2O3" => "R2O3",
    "Cr2O3" => "R2O3",
    "Pr2O3" => "R2O3",
    "SiO2"  => "RO2",
    "TiO2"  => "RO2",
    "ZrO2"  => "RO2",
    "SnO2"  => "RO2",
    "P2O5"  => "RO2",
    "V2O5"  => "RO2",
    "CeO2"  => "RO2"
  }.freeze

  # Conversion factor from ferrous oxide (FeO) to ferric oxide (Fe2O3).
  FEO_TO_FE2O3_FACTOR = 1.1113

  module_function

  # Normalizes a hash of major oxide weight percentages (including LOI) so that
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
