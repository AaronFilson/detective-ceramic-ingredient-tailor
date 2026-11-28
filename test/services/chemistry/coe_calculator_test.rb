# frozen_string_literal: true

require "test_helper"

module Chemistry
  class CoeCalculatorTest < ActiveSupport::TestCase
    test "flags high-alkali Na2O/K2O glaze as high crazing risk (> 8.4)" do
      high_alkali = {
        "SiO2"  => 54.0,
        "Al2O3" => 18.0,
        "CaO"   => 12.0,
        "Na2O"  => 9.0,
        "K2O"   => 4.5,
        "MgO"   => 0.5,
        "LOI"   => 2.0
      }

      result = CoeCalculator.call(high_alkali)

      assert_operator result.coe, :>, 8.4
      assert_equal :high_crazing, result.risk_level
      assert_equal "High Crazing Risk", result.risk_label
      assert result.badge_classes.present?
      assert_includes result.guidance, "craze"
      assert_equal 3, result.top_contributors.size
      assert_equal "Na2O", result.top_contributors.first[:oxide]
      assert_operator result.top_contributors.first[:contribution], :>, 3.0
    end

    test "scores balanced stoneware glaze in balanced fit window (6.2-7.2)" do
      # Classic Cone 6 stoneware clear (G2926B-style)
      stoneware_clear = {
        "SiO2"  => 63.0,
        "Al2O3" => 11.0,
        "CaO"   => 11.0,
        "Na2O"  => 4.4,
        "K2O"   => 1.5,
        "MgO"   => 0.5,
        "LOI"   => 3.0
      }
      minors = { "B2O3" => 5.6 }

      result = CoeCalculator.call(stoneware_clear, minor_oxides: minors)

      assert_in_delta 6.6, result.coe, 0.6
      assert_equal :balanced_fit, result.risk_level
      assert_equal "Balanced Fit", result.risk_label
      assert_equal 3, result.top_contributors.size
    end

    test "flags high-SiO2/B2O3/Li2O/MgO low-expansion glaze as shivering watch (< 5.5)" do
      low_expansion = {
        "SiO2"  => 68.0,
        "Al2O3" => 11.5,
        "MgO"   => 5.5,
        "CaO"   => 3.0,
        "Na2O"  => 0.6,
        "K2O"   => 0.4,
        "LOI"   => 2.0
      }
      minors = { "B2O3" => 6.0, "Li2O" => 3.0 }

      result = CoeCalculator.call(low_expansion, minor_oxides: minors)

      assert_operator result.coe, :<, 5.5
      assert_equal :shivering_risk, result.risk_level
      assert_equal "Shivering Watch", result.risk_label
      assert_includes result.guidance.downcase, "shivering"
    end

    test "classifies moderate crazing risk between 7.4 and 8.4" do
      moderate_glaze = {
        "SiO2"  => 58.0,
        "Al2O3" => 15.0,
        "CaO"   => 14.0,
        "Na2O"  => 4.8,
        "K2O"   => 4.2,
        "MgO"   => 1.0,
        "LOI"   => 3.0
      }

      result = CoeCalculator.call(moderate_glaze)

      assert_operator result.coe, :>, 7.4
      assert_operator result.coe, :<=, 8.4
      assert_equal :moderate_crazing, result.risk_level
      assert_equal "Moderate Crazing", result.risk_label
    end

    test "produces matching COE whether called with UMF hash or fired oxide weight percents" do
      majors = {
        "SiO2"  => 56.0,
        "Al2O3" => 13.0,
        "Fe2O3" => 2.5,
        "CaO"   => 11.5,
        "MgO"   => 0.8,
        "Na2O"  => 3.0,
        "K2O"   => 1.7,
        "LOI"   => 6.5
      }
      minors = { "B2O3" => 5.0 }

      umf = Chemistry::UmfCalculator.call(majors, minor_oxides: minors)
      from_oxides = CoeCalculator.call(majors, minor_oxides: minors)
      from_umf = CoeCalculator.call(umf)
      from_both = CoeCalculator.call(umf, oxides: majors, minor_oxides: minors)

      assert_in_delta from_oxides.coe, from_umf.coe, 0.05
      assert_equal from_oxides.coe, from_both.coe
      assert_equal from_oxides.risk_level, from_umf.risk_level
    end

    test "ignores LOI and volatile SO3/F when normalizing to fired weight basis" do
      low_loi = { "SiO2" => 60.0, "Al2O3" => 15.0, "CaO" => 15.0, "Na2O" => 5.0, "K2O" => 5.0, "LOI" => 0.0 }
      high_loi = { "SiO2" => 30.0, "Al2O3" => 7.5, "CaO" => 7.5, "Na2O" => 2.5, "K2O" => 2.5, "LOI" => 50.0 }

      res_low = CoeCalculator.call(low_loi)
      res_high = CoeCalculator.call(high_loi, minor_oxides: { "SO3" => 2.0, "F" => 1.0 })

      assert_in_delta res_low.coe, res_high.coe, 0.01
    end

    test "handles empty or nil inputs safely" do
      result = CoeCalculator.call(nil)
      assert_equal 0.0, result.coe
      assert_equal :shivering_risk, result.risk_level
      assert_equal [], result.top_contributors
    end
  end
end
