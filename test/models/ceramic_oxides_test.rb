# frozen_string_literal: true

require "test_helper"

class CeramicOxidesTest < ActiveSupport::TestCase
  test "exports exact canonical oxide keys" do
    expected = %w[SiO2 Al2O3 Fe2O3 CaO MgO Na2O K2O TiO2 P2O5 MnO LOI]
    assert_equal expected, CeramicOxides::KEYS
  end

  test "exports stoichiometric element-to-oxide conversion factors" do
    assert_equal %w[Si Al Fe Ca Mg Na K Ti P Mn], CeramicOxides::ELEMENT_TO_OXIDE_FACTORS.keys
    assert_in_delta 2.1393, CeramicOxides::ELEMENT_TO_OXIDE_FACTORS["Si"][:factor], 0.001
    assert_equal "Al2O3", CeramicOxides::ELEMENT_TO_OXIDE_FACTORS["Al"][:oxide]
    assert_in_delta 1.1113, CeramicOxides::FEO_TO_FE2O3_FACTOR, 0.001
  end

  test "normalize scales oxides and LOI to 100 percent and fills missing keys with zero" do
    normalized = CeramicOxides.normalize(
      SiO2: 60.0,
      Al2O3: 20.0,
      Fe2O3: 5.0,
      K2O: 5.0,
      LOI: 10.0
    )

    assert_equal CeramicOxides::KEYS, normalized.keys
    assert_in_delta 100.0, normalized.values.sum, 0.01
    assert_in_delta 60.0, normalized["SiO2"], 0.001
    assert_equal 0.0, normalized["CaO"]
  end

  test "normalize scales unnormalized totals to 100 percent" do
    normalized = CeramicOxides.normalize("SiO2" => 30.0, "Al2O3" => 10.0, "LOI" => 10.0)

    assert_in_delta 100.0, normalized.values.sum, 0.01
    assert_in_delta 60.0, normalized["SiO2"], 0.001
    assert_in_delta 20.0, normalized["Al2O3"], 0.001
    assert_in_delta 20.0, normalized["LOI"], 0.001
  end

  test "normalize returns nil when total is zero" do
    assert_nil CeramicOxides.normalize({})
    assert_nil CeramicOxides.normalize("SiO2" => 0, "Al2O3" => -5)
  end
end
