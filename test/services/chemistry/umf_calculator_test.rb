# frozen_string_literal: true

require "test_helper"

module Chemistry
  class UmfCalculatorTest < ActiveSupport::TestCase
    test "calculates unity molecular formula for typical stoneware clay" do
      stoneware = {
        "SiO2"  => 62.40,
        "Al2O3" => 20.10,
        "Fe2O3" => 2.20,
        "CaO"   => 1.80,
        "MgO"   => 1.10,
        "Na2O"  => 0.90,
        "K2O"   => 2.50,
        "TiO2"  => 1.00,
        "P2O5"  => 0.10,
        "MnO"   => 0.05,
        "LOI"   => 7.85
      }

      umf = Chemistry::UmfCalculator.call(stoneware)

      # Verify top-level JSONB contract keys (all string keys)
      expected_keys = %w[
        fluxes intermediates glass_formers oxides
        flux_total r2o_total ro_total si_al_ratio
        equivalent_weight formula_weight
      ]
      assert_equal expected_keys.sort, umf.keys.sort

      # Hand-computed molar equivalents per 100g (RO includes divalent MnO per Seger / glazecalc):
      # CaO: 1.80 / 56.08 = 0.032097
      # MgO: 1.10 / 40.30 = 0.027295
      # MnO: 0.05 / 70.94 = 0.000705
      # Na2O: 0.90 / 61.98 = 0.014521
      # K2O: 2.50 / 94.20 = 0.026539
      expected_flux_moles = (1.80 / 56.08) + (1.10 / 40.30) + (0.05 / 70.94) + (0.90 / 61.98) + (2.50 / 94.20)
      expected_eq_weight  = 100.0 / expected_flux_moles
      expected_fw         = expected_eq_weight * (1.0 - 7.85 / 100.0)
      expected_si_al      = (62.40 / 60.08) / (20.10 / 101.96)

      assert_in_delta 1.0, umf["flux_total"], 0.0001
      assert_in_delta 1.0, umf["fluxes"].values.sum, 0.0005
      assert_in_delta 1.0, umf["ro_total"] + umf["r2o_total"], 0.0005
      assert_in_delta ((1.80 / 56.08) + (1.10 / 40.30) + (0.05 / 70.94)) / expected_flux_moles, umf["ro_total"], 0.0002
      assert_in_delta ((0.90 / 61.98) + (2.50 / 94.20)) / expected_flux_moles, umf["r2o_total"], 0.0002

      assert_in_delta expected_si_al, umf["si_al_ratio"], 0.001
      assert_in_delta expected_eq_weight, umf["equivalent_weight"], 0.02
      assert_in_delta expected_fw, umf["formula_weight"], 0.02

      # Verify groupings and absence of LOI in fired oxides
      assert_equal %w[CaO MgO MnO Na2O K2O], umf["fluxes"].keys
      assert_equal %w[Al2O3 Fe2O3], umf["intermediates"].keys
      assert_equal %w[SiO2 TiO2 P2O5], umf["glass_formers"].keys
      assert_not_includes umf["oxides"].keys, "LOI"

      # Verify glazecalc stoichiometry identity: amountUnity == (wt/100/mw) * equivalent_weight
      stoneware.except("LOI").each do |oxide, wt_pct|
        moles_per_gram = (wt_pct / 100.0) / Chemistry::UmfCalculator::MOLECULAR_WEIGHTS[oxide]
        glazecalc_unity = (moles_per_gram * umf["equivalent_weight"]).round(4)
        assert_in_delta glazecalc_unity, umf["oxides"][oxide], 0.001, "Mismatch for #{oxide}"
      end
    end

    test "calculates exact stoichiometry for pure potash feldspar (K2O.Al2O3.6SiO2)" do
      # Ideal orthoclase: K2O 16.92%, Al2O3 18.32%, SiO2 64.76%, LOI 0%
      orthoclase = {
        SiO2: 64.76,
        Al2O3: 18.32,
        K2O: 16.92,
        LOI: 0.0
      }

      umf = Chemistry::UmfCalculator.call(orthoclase)

      assert_equal 1.0, umf["flux_total"]
      assert_equal 1.0, umf["r2o_total"]
      assert_equal 0.0, umf["ro_total"]
      assert_equal 1.0, umf["fluxes"]["K2O"]
      assert_in_delta 1.0, umf["intermediates"]["Al2O3"], 0.005
      assert_in_delta 6.0, umf["glass_formers"]["SiO2"], 0.01
      assert_in_delta 6.0, umf["si_al_ratio"], 0.01
      assert_in_delta 556.64, umf["equivalent_weight"], 0.25
      assert_equal umf["equivalent_weight"], umf["formula_weight"]
    end

    test "distinguishes raw equivalent_weight and fired formula_weight using LOI (whiting CaCO3)" do
      # Whiting (CaCO3): MW 100.09, CaO 56.03%, LOI 43.97%
      whiting = { "CaO" => 56.03, "LOI" => 43.97 }

      umf = Chemistry::UmfCalculator.call(whiting)

      assert_equal 1.0, umf["flux_total"]
      assert_equal 1.0, umf["fluxes"]["CaO"]
      assert_nil umf["si_al_ratio"]
      assert_in_delta 100.09, umf["equivalent_weight"], 0.05
      assert_in_delta 56.08, umf["formula_weight"], 0.05
    end

    test "avoids ZeroDivisionError for zero-flux pure kaolin and computes exact 2:1 Si:Al ratio" do
      # Ideal kaolinite Al2O3.2SiO2.2H2O: SiO2 46.55%, Al2O3 39.50%, LOI 13.95%
      kaolin = { "SiO2" => 46.55, "Al2O3" => 39.50, "LOI" => 13.95 }

      umf = Chemistry::UmfCalculator.call(kaolin)

      assert_equal 0.0, umf["flux_total"]
      assert_equal 0.0, umf["ro_total"]
      assert_equal 0.0, umf["r2o_total"]
      assert_equal 100.0, umf["equivalent_weight"]
      assert_in_delta 86.05, umf["formula_weight"], 0.01
      assert_in_delta 2.0, umf["si_al_ratio"], 0.005
      assert_in_delta (46.55 / 60.08), umf["glass_formers"]["SiO2"], 0.0005
      assert_in_delta (39.50 / 101.96), umf["intermediates"]["Al2O3"], 0.0005
    end

    test "handles pure silica and empty or malformed inputs gracefully" do
      silica_umf = Chemistry::UmfCalculator.call({ "SiO2" => "100.0", "Al2O3" => -2.0 })
      assert_equal 0.0, silica_umf["flux_total"]
      assert_nil silica_umf["si_al_ratio"]
      assert_equal 100.0, silica_umf["equivalent_weight"]
      assert_equal 100.0, silica_umf["formula_weight"]
      assert_in_delta (100.0 / 60.08), silica_umf["glass_formers"]["SiO2"], 0.0005
      assert_equal 0.0, silica_umf["intermediates"]["Al2O3"]

      empty_umf = Chemistry::UmfCalculator.call(nil)
      assert_equal 0.0, empty_umf["flux_total"]
      assert_nil empty_umf["si_al_ratio"]
      assert_equal 100.0, empty_umf["equivalent_weight"]
      assert_equal 100.0, empty_umf["formula_weight"]
    end

    test "places minor ceramic oxides into exact glazecalc R2O/RO/R2O3/RO2 groups via minor_oxides keyword" do
      # Spodumene-bearing pegmatite glaze rock with Li2O (R2O), BaO/ZnO/SrO/CuO/CoO/NiO (RO),
      # B2O3/Cr2O3/Pr2O3 (R2O3), ZrO2/SnO2/V2O5/CeO2 (RO2), plus volatile SO3 & F (excluded!).
      majors = {
        "SiO2"  => 62.0,
        "Al2O3" => 17.5,
        "Fe2O3" => 0.5,
        "CaO"   => 1.5,
        "MgO"   => 0.5,
        "Na2O"  => 2.0,
        "K2O"   => 4.0,
        "LOI"   => 2.0
      }
      minors = {
        "Li2O"  => 2.5,
        "B2O3"  => 1.5,
        "SrO"   => 0.5,
        "BaO"   => 1.0,
        "ZnO"   => 0.8,
        "ZrO2"  => 1.2,
        "SnO2"  => 0.6,
        "Cr2O3" => 0.2,
        "CuO"   => 0.4,
        "CoO"   => 0.2,
        "NiO"   => 0.2,
        "V2O5"  => 0.3,
        "CeO2"  => 0.4,
        "Pr2O3" => 0.2,
        "SO3"   => 0.8,
        "F"     => 0.6
      }

      umf = Chemistry::UmfCalculator.call(majors, minor_oxides: minors)

      # Exact group placement matching CeramicOxides::ALL_OXIDE_GROUPS
      %w[CaO MgO MnO SrO BaO ZnO CuO CoO NiO Na2O K2O Li2O].each do |flux_ox|
        assert_includes umf["fluxes"].keys, flux_ox
      end
      %w[Al2O3 Fe2O3 B2O3 Cr2O3 Pr2O3].each do |inter_ox|
        assert_includes umf["intermediates"].keys, inter_ox
      end
      %w[SiO2 TiO2 P2O5 ZrO2 SnO2 V2O5 CeO2].each do |gf_ox|
        assert_includes umf["glass_formers"].keys, gf_ox
      end

      # Volatiles SO3 and F are excluded from fired UMF
      assert_not_includes umf["oxides"].keys, "SO3"
      assert_not_includes umf["oxides"].keys, "F"
      assert_not_includes umf["oxides"].keys, "LOI"

      # Hand-check R2O, RO, flux_total, equivalent_weight, formula_weight
      mw = CeramicOxides::ALL_OXIDE_MOLAR_WEIGHTS
      r2o_moles = (2.0 / mw["Na2O"]) + (4.0 / mw["K2O"]) + (2.5 / mw["Li2O"])
      ro_moles = (1.5 / mw["CaO"]) + (0.5 / mw["MgO"]) + (0.5 / mw["SrO"]) +
        (1.0 / mw["BaO"]) + (0.8 / mw["ZnO"]) + (0.4 / mw["CuO"]) +
        (0.2 / mw["CoO"]) + (0.2 / mw["NiO"])
      flux_moles = r2o_moles + ro_moles
      expected_eq = 100.0 / flux_moles
      expected_fw = expected_eq * (1.0 - 2.0 / 100.0)

      assert_in_delta 1.0, umf["flux_total"], 0.0005
      assert_in_delta r2o_moles / flux_moles, umf["r2o_total"], 0.0005
      assert_in_delta ro_moles / flux_moles, umf["ro_total"], 0.0005
      assert_in_delta expected_eq, umf["equivalent_weight"], 0.02
      assert_in_delta expected_fw, umf["formula_weight"], 0.02
      assert_in_delta (2.5 / mw["Li2O"]) / flux_moles, umf["fluxes"]["Li2O"], 0.0005
      assert_in_delta (1.5 / mw["B2O3"]) / flux_moles, umf["intermediates"]["B2O3"], 0.0005
      assert_in_delta (1.2 / mw["ZrO2"]) / flux_moles, umf["glass_formers"]["ZrO2"], 0.0005
    end

    test "automatically picks up positive minor ceramic oxides present directly in oxides_hash" do
      spodumene = {
        "SiO2"  => 64.58,
        "Al2O3" => 27.40,
        "Li2O"  => 8.02,
        "LOI"   => 0.0
      }

      umf = Chemistry::UmfCalculator.call(spodumene)

      # Ideal spodumene Li2O.Al2O3.4SiO2
      assert_equal 1.0, umf["flux_total"]
      assert_equal 1.0, umf["r2o_total"]
      assert_equal 0.0, umf["ro_total"]
      assert_equal 1.0, umf["fluxes"]["Li2O"]
      assert_in_delta 1.0, umf["intermediates"]["Al2O3"], 0.01
      assert_in_delta 4.0, umf["glass_formers"]["SiO2"], 0.02
      assert_in_delta 372.57, umf["equivalent_weight"], 0.5
    end

    test "returns byte-for-byte identical keys when minor_oxides is empty or all-zero" do
      base = { "SiO2" => 65.0, "Al2O3" => 20.0, "K2O" => 5.0, "CaO" => 2.0, "LOI" => 8.0 }

      plain = Chemistry::UmfCalculator.call(base)
      with_empty = Chemistry::UmfCalculator.call(base, minor_oxides: {})
      with_zeros = Chemistry::UmfCalculator.call(base, minor_oxides: { "Li2O" => 0.0, "B2O3" => 0.0, "SO3" => 0.5, "F" => 0.3 })

      assert_equal plain, with_empty
      assert_equal plain, with_zeros
    end

    test "accepts unbraced string-keyed and symbol-keyed oxide arguments cleanly" do
      from_strings = Chemistry::UmfCalculator.call(
        "SiO2" => 64.76, "Al2O3" => 18.32, "K2O" => 16.92, "LOI" => 0.0
      )
      from_symbols = Chemistry::UmfCalculator.call(
        SiO2: 64.76, Al2O3: 18.32, K2O: 16.92, LOI: 0.0
      )

      assert_equal from_strings, from_symbols
      assert_equal 1.0, from_strings["flux_total"]
      assert_in_delta 6.0, from_strings["si_al_ratio"], 0.01
    end
  end
end
