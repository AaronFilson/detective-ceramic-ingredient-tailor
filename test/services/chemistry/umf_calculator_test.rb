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

      # Hand-computed molar equivalents per 100g:
      # CaO: 1.80 / 56.08 = 0.032097
      # MgO: 1.10 / 40.30 = 0.027295
      # Na2O: 0.90 / 61.98 = 0.014521
      # K2O: 2.50 / 94.20 = 0.026539
      # Flux sum = 0.100452
      expected_flux_moles = (1.80 / 56.08) + (1.10 / 40.30) + (0.90 / 61.98) + (2.50 / 94.20)
      expected_eq_weight  = 100.0 / expected_flux_moles
      expected_fw         = expected_eq_weight * (1.0 - 7.85 / 100.0)
      expected_si_al      = (62.40 / 60.08) / (20.10 / 101.96)

      assert_in_delta 1.0, umf["flux_total"], 0.0001
      assert_in_delta 1.0, umf["fluxes"].values.sum, 0.0005
      assert_in_delta 1.0, umf["ro_total"] + umf["r2o_total"], 0.0005
      assert_in_delta ((1.80 / 56.08) + (1.10 / 40.30)) / expected_flux_moles, umf["ro_total"], 0.0002
      assert_in_delta ((0.90 / 61.98) + (2.50 / 94.20)) / expected_flux_moles, umf["r2o_total"], 0.0002

      assert_in_delta expected_si_al, umf["si_al_ratio"], 0.001
      assert_in_delta expected_eq_weight, umf["equivalent_weight"], 0.02
      assert_in_delta expected_fw, umf["formula_weight"], 0.02

      # Verify groupings and absence of LOI in fired oxides
      assert_equal %w[CaO MgO Na2O K2O], umf["fluxes"].keys
      assert_equal %w[Al2O3 Fe2O3 MnO], umf["intermediates"].keys
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
  end
end
