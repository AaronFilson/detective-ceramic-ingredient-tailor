# frozen_string_literal: true

require "test_helper"

module Inference
  class ObservationModifierServiceTest < ActiveSupport::TestCase
    setup do
      @sample = UserSample.create!(title: "Puget Sound Glacial Clay", material_category: :wild_clay)

      # Realistic PNW stoneware clay baseline ranges summing to 100.0% at medians
      @baseline_ranges = {
        "SiO2"  => { "min" => 54.0, "q1" => 57.5, "median" => 60.0, "q3" => 63.0, "max" => 67.0, "iqr" => 5.5 },
        "Al2O3" => { "min" => 14.0, "q1" => 16.5, "median" => 18.0, "q3" => 20.0, "max" => 23.0, "iqr" => 3.5 },
        "Fe2O3" => { "min" => 2.0,  "q1" => 3.2,  "median" => 4.5,  "q3" => 6.2,  "max" => 8.5,  "iqr" => 3.0 },
        "CaO"   => { "min" => 0.8,  "q1" => 1.5,  "median" => 2.2,  "q3" => 3.6,  "max" => 6.0,  "iqr" => 2.1 },
        "MgO"   => { "min" => 0.9,  "q1" => 1.4,  "median" => 1.9,  "q3" => 2.5,  "max" => 3.5,  "iqr" => 1.1 },
        "Na2O"  => { "min" => 0.7,  "q1" => 1.2,  "median" => 1.8,  "q3" => 2.4,  "max" => 3.4,  "iqr" => 1.2 },
        "K2O"   => { "min" => 1.2,  "q1" => 2.0,  "median" => 2.6,  "q3" => 3.4,  "max" => 4.5,  "iqr" => 1.4 },
        "TiO2"  => { "min" => 0.4,  "q1" => 0.6,  "median" => 0.8,  "q3" => 1.0,  "max" => 1.4,  "iqr" => 0.4 },
        "P2O5"  => { "min" => 0.05, "q1" => 0.08, "median" => 0.1,  "q3" => 0.15, "max" => 0.3,  "iqr" => 0.07 },
        "MnO"   => { "min" => 0.02, "q1" => 0.05, "median" => 0.1,  "q3" => 0.15, "max" => 0.25, "iqr" => 0.1 },
        "LOI"   => { "min" => 4.5,  "q1" => 6.5,  "median" => 8.0,  "q3" => 9.8,  "max" => 12.5, "iqr" => 3.3 }
      }
    end

    test "returns normalized baseline with empty reasoning_log when field_observation is nil" do
      result = ObservationModifierService.call(@baseline_ranges, nil)

      assert_equal 100.0, result.oxides.values.sum.round(2)
      assert_equal [], result.reasoning_log
      assert_equal 0.0, result.confidence_adjustment
      assert_equal 60.0, result.oxides["SiO2"]
      assert_in_delta 1.0, result.umf_formula["flux_total"], 0.0001
      assert_ranges_consistent(result)
    end

    test "gracefully handles minimal min/median/max ranges with symbol keys" do
      minimal = {
        SiO2: { min: 55.0, median: 62.0, max: 68.0 },
        Al2O3: { min: 15.0, median: 20.0, max: 25.0 },
        CaO: { min: 1.0, median: 2.0, max: 4.0 },
        LOI: { min: 6.0, median: 8.0, max: 10.0 }
      }
      obs = @sample.field_observations.build(vinegar_fizz: :vigorous)

      result = ObservationModifierService.call(minimal, obs)

      assert_equal 100.0, result.oxides.values.sum.round(2)
      assert_equal CeramicOxides::KEYS, result.oxides.keys
      assert_operator result.oxides["CaO"], :>, 2.0
      assert_ranges_consistent(result)
    end

    test "vinegar_fizz vigorous significantly elevates normalized CaO and LOI via CaCO3 stoichiometry" do
      baseline = ObservationModifierService.call(@baseline_ranges, nil)
      obs = @sample.field_observations.build(vinegar_fizz: :vigorous)
      result = ObservationModifierService.call(@baseline_ranges, obs)

      assert_equal 100.0, result.oxides.values.sum.round(2)
      assert_operator result.oxides["CaO"], :>, baseline.oxides["CaO"] + 2.5
      assert_operator result.oxides["LOI"], :>, baseline.oxides["LOI"] + 1.5
      assert_operator result.umf_formula["fluxes"]["CaO"], :>, baseline.umf_formula["fluxes"]["CaO"]
      assert_operator result.confidence_adjustment, :>, 0.0
      assert result.reasoning_log.any? { |entry| entry.include?("CaO") && entry.include?("LOI") && entry.include?("CaCO3") }
      assert_ranges_consistent(result)
    end

    test "vinegar_fizz slight produces modest CaO and LOI increase smaller than vigorous" do
      baseline = ObservationModifierService.call(@baseline_ranges, nil)
      slight = ObservationModifierService.call(@baseline_ranges, @sample.field_observations.build(vinegar_fizz: :slight))
      vigorous = ObservationModifierService.call(@baseline_ranges, @sample.field_observations.build(vinegar_fizz: :vigorous))

      assert_operator slight.oxides["CaO"], :>, baseline.oxides["CaO"]
      assert_operator slight.oxides["LOI"], :>, baseline.oxides["LOI"]
      assert_operator slight.oxides["CaO"], :<, vigorous.oxides["CaO"]
      assert_operator slight.oxides["LOI"], :<, vigorous.oxides["LOI"]
      assert slight.reasoning_log.any? { |entry| entry.match?(/slight vinegar fizz/i) }
    end

    test "red/terracotta color shifts low-iron baseline Fe2O3 into 4.0%-9.0% range" do
      low_iron_ranges = @baseline_ranges.deep_dup
      low_iron_ranges["Fe2O3"] = { "min" => 0.4, "q1" => 0.8, "median" => 1.2, "q3" => 2.5, "max" => 5.0 }

      obs = @sample.field_observations.build(fired_color: "terracotta red")
      result = ObservationModifierService.call(low_iron_ranges, obs)

      assert_equal 100.0, result.oxides.values.sum.round(2)
      assert_operator result.oxides["Fe2O3"], :>=, 4.0
      assert_operator result.oxides["Fe2O3"], :<=, 9.0
      assert result.reasoning_log.any? { |entry| entry.include?("Fe2O3") && entry.include?("terracotta red") }
      assert_ranges_consistent(result)
    end

    test "buff/white fired color caps Fe2O3 below 1.5%" do
      obs = @sample.field_observations.build(fired_color: "buff white")
      result = ObservationModifierService.call(@baseline_ranges, obs)

      assert_equal 100.0, result.oxides.values.sum.round(2)
      assert_operator result.oxides["Fe2O3"], :<, 1.5
      assert_operator result.oxide_ranges["Fe2O3"]["max"], :<=, 1.5
      assert result.reasoning_log.any? { |entry| entry.include?("Fe2O3") && entry.include?("1.5%") }
      assert_ranges_consistent(result)
    end

    test "fired color takes precedence over conflicting dark raw color with organic carbon burnout LOI bump" do
      baseline = ObservationModifierService.call(@baseline_ranges, nil)
      obs = @sample.field_observations.build(raw_color: "dark chocolate brown", fired_color: "ivory porcelain")
      result = ObservationModifierService.call(@baseline_ranges, obs)

      assert_equal 100.0, result.oxides.values.sum.round(2)
      assert_operator result.oxides["Fe2O3"], :<, 1.5
      assert_operator result.oxides["LOI"], :>, baseline.oxides["LOI"] + 1.0
      assert result.reasoning_log.any? { |entry| entry.match?(/carbon burnout/i) && entry.include?("overrides") }
      assert_ranges_consistent(result)
    end

    test "fired color overrides pale raw color when firing terracotta" do
      low_iron_ranges = @baseline_ranges.deep_dup
      low_iron_ranges["Fe2O3"] = { "min" => 0.5, "q1" => 1.0, "median" => 1.5, "q3" => 3.0, "max" => 6.0 }

      obs = @sample.field_observations.build(raw_color: "pale cream", fired_color: "rust red")
      result = ObservationModifierService.call(low_iron_ranges, obs)

      assert_operator result.oxides["Fe2O3"], :>=, 4.0
      assert_operator result.oxides["Fe2O3"], :<=, 9.0
      assert result.reasoning_log.any? { |entry| entry.include?("overrides") && entry.include?("rust red") }
    end

    test "parse_cone handles full Orton cone notation cleanly" do
      assert_equal(-22, ObservationModifierService.parse_cone("022"))
      assert_equal(-6, ObservationModifierService.parse_cone("06"))
      assert_equal(-6, ObservationModifierService.parse_cone("Cone 06"))
      assert_equal(-4, ObservationModifierService.parse_cone("Δ04"))
      assert_equal(-1, ObservationModifierService.parse_cone("01"))
      assert_equal 1, ObservationModifierService.parse_cone("1")
      assert_equal 6, ObservationModifierService.parse_cone("6")
      assert_equal 10, ObservationModifierService.parse_cone("cone 10")
      assert_equal 14, ObservationModifierService.parse_cone("14")
      assert_nil ObservationModifierService.parse_cone("0")
      assert_nil ObservationModifierService.parse_cone("00")
      assert_nil ObservationModifierService.parse_cone("")
      assert_nil ObservationModifierService.parse_cone("unknown")
    end

    test "melted_fluid at cone 06 to 6 boosts alkali fluxes, CaO, and Fe2O3" do
      baseline = ObservationModifierService.call(@baseline_ranges, nil)
      obs = @sample.field_observations.build(fired_cone: "06", melt_state: :melted_fluid)
      result = ObservationModifierService.call(@baseline_ranges, obs)

      assert_equal 100.0, result.oxides.values.sum.round(2)
      assert_operator(result.oxides["Na2O"] + result.oxides["K2O"], :>, baseline.oxides["Na2O"] + baseline.oxides["K2O"] + 2.0)
      assert_operator result.oxides["CaO"], :>, baseline.oxides["CaO"] + 1.5
      assert_operator result.oxides["Fe2O3"], :>, baseline.oxides["Fe2O3"] + 0.5
      assert_operator result.umf_formula["equivalent_weight"], :<, baseline.umf_formula["equivalent_weight"]
      assert result.reasoning_log.any? { |entry| entry.include?("Cone 06") && entry.match?(/melted\/fluid/i) }
      assert_ranges_consistent(result)
    end

    test "bloated at cone 6 boosts Fe2O3, alkali fluxes, CaO, and notes gas evolution" do
      baseline = ObservationModifierService.call(@baseline_ranges, nil)
      obs = @sample.field_observations.build(fired_cone: "6", melt_state: :bloated)
      result = ObservationModifierService.call(@baseline_ranges, obs)

      assert_equal 100.0, result.oxides.values.sum.round(2)
      assert_operator result.oxides["Fe2O3"], :>, baseline.oxides["Fe2O3"] + 1.0
      assert_operator(result.oxides["Na2O"] + result.oxides["K2O"], :>, baseline.oxides["Na2O"] + baseline.oxides["K2O"] + 1.5)
      assert result.reasoning_log.any? { |entry| entry.match?(/bloated/i) && entry.match?(/gas evolution/i) }
    end

    test "refractory_chalky at cone 10 boosts Al2O3 and SiO2 and dampens fluxes" do
      baseline = ObservationModifierService.call(@baseline_ranges, nil)
      obs = @sample.field_observations.build(fired_cone: "10", melt_state: :refractory_chalky)
      result = ObservationModifierService.call(@baseline_ranges, obs)

      assert_equal 100.0, result.oxides.values.sum.round(2)
      assert_operator result.oxides["Al2O3"], :>, baseline.oxides["Al2O3"] + 3.0
      assert_operator result.oxides["SiO2"], :>=, baseline.oxides["SiO2"]
      assert_operator result.oxides["Na2O"], :<, baseline.oxides["Na2O"] * 0.7
      assert_operator result.oxides["K2O"], :<, baseline.oxides["K2O"] * 0.7
      assert_operator result.oxides["CaO"], :<, baseline.oxides["CaO"] * 0.7
      assert_operator result.umf_formula["equivalent_weight"], :>, baseline.umf_formula["equivalent_weight"]
      assert result.reasoning_log.any? { |entry| entry.include?("Cone 10") && entry.match?(/refractory\/chalky/i) }
      assert_ranges_consistent(result)
    end

    test "vitrified_tight at cone 6 logs stoneware vitrification confirmation and low-fire refractory logs modest note" do
      vitrified = ObservationModifierService.call(
        @baseline_ranges,
        @sample.field_observations.build(fired_cone: "6", melt_state: :vitrified_tight)
      )
      assert_operator vitrified.confidence_adjustment, :>, 0.0
      assert vitrified.reasoning_log.any? { |entry| entry.match?(/stoneware vitrification/i) }

      low_refractory = ObservationModifierService.call(
        @baseline_ranges,
        @sample.field_observations.build(fired_cone: "06", melt_state: :refractory_chalky)
      )
      assert low_refractory.reasoning_log.any? { |entry| entry.match?(/refractory\/chalky/i) && entry.include?("Cone 06") }
    end

    test "high_plastic weights toward kaolinite/illite clay ratios while short_non_plastic weights toward feldspar/quartz" do
      baseline = ObservationModifierService.call(@baseline_ranges, nil)

      plastic = ObservationModifierService.call(
        @baseline_ranges,
        @sample.field_observations.build(plasticity: :high_plastic)
      )
      assert_operator plastic.oxides["Al2O3"], :>, baseline.oxides["Al2O3"] + 1.5
      assert_operator plastic.oxides["LOI"], :>, baseline.oxides["LOI"] + 1.0
      assert_operator plastic.oxides["SiO2"], :<, baseline.oxides["SiO2"] - 1.5
      assert plastic.reasoning_log.any? { |entry| entry.match?(/kaolinite\/illite/i) }

      short = ObservationModifierService.call(
        @baseline_ranges,
        @sample.field_observations.build(plasticity: :short_non_plastic)
      )
      assert_operator short.oxides["SiO2"], :>, baseline.oxides["SiO2"] + 1.0
      assert_operator(short.oxides["K2O"] + short.oxides["Na2O"], :>, baseline.oxides["K2O"] + baseline.oxides["Na2O"] + 1.0)
      assert_operator short.oxides["LOI"], :<, baseline.oxides["LOI"] - 2.0
      assert short.reasoning_log.any? { |entry| entry.match?(/feldspar\/quartz/i) }
    end

    test "slaking_behavior fast_disintegration reinforces LOI while no_slake reduces LOI" do
      baseline = ObservationModifierService.call(@baseline_ranges, nil)

      fast = ObservationModifierService.call(
        @baseline_ranges,
        @sample.field_observations.build(slaking_behavior: :fast_disintegration)
      )
      assert_operator fast.oxides["LOI"], :>, baseline.oxides["LOI"]
      assert fast.reasoning_log.any? { |entry| entry.match?(/unconsolidated/i) }

      indurated = ObservationModifierService.call(
        @baseline_ranges,
        @sample.field_observations.build(slaking_behavior: :no_slake)
      )
      assert_operator indurated.oxides["LOI"], :<, baseline.oxides["LOI"]
      assert indurated.reasoning_log.any? { |entry| entry.match?(/indurated shale/i) }
    end

    test "combined rules preserve exact 100.0% sum, consistent ranges, all reasoning entries, and caps" do
      baseline = ObservationModifierService.call(@baseline_ranges, nil)
      obs = @sample.field_observations.build(
        vinegar_fizz: :vigorous,
        raw_color: "dark brown",
        fired_color: "terracotta",
        fired_cone: "06",
        melt_state: :melted_fluid,
        plasticity: :high_plastic,
        slaking_behavior: :fast_disintegration
      )

      result = ObservationModifierService.call(@baseline_ranges, obs)

      assert_equal 100.0, result.oxides.values.sum.round(2)
      assert result.oxides.values.all? { |v| v >= 0.0 }
      assert_equal 5, result.reasoning_log.length
      assert_operator result.oxides["CaO"], :>, baseline.oxides["CaO"] + 3.0
      assert_operator result.oxides["LOI"], :>, baseline.oxides["LOI"] + 3.0
      assert_operator result.confidence_adjustment, :<=, ObservationModifierService::MAX_CONFIDENCE_ADJUSTMENT
      assert_in_delta 1.0, result.umf_formula["flux_total"], 0.0001
      assert_ranges_consistent(result)
    end

    test "white fired color cap is respected even when combined with low-fire melted_fluid" do
      obs = @sample.field_observations.build(
        fired_color: "white porcelain",
        fired_cone: "6",
        melt_state: :melted_fluid
      )

      result = ObservationModifierService.call(@baseline_ranges, obs)

      assert_equal 100.0, result.oxides.values.sum.round(2)
      assert_operator result.oxides["Fe2O3"], :<, 1.5
      assert_equal 2, result.reasoning_log.length
      assert result.reasoning_log.last.include?("low-iron cap")
    end

    private

    def assert_ranges_consistent(result)
      CeramicOxides::KEYS.each do |oxide|
        r = result.oxide_ranges.fetch(oxide)
        val = result.oxides.fetch(oxide)
        assert_equal val, r["median"], "Range median mismatch for #{oxide}"
        assert_operator r["min"], :>=, 0.0, "Negative min for #{oxide}"
        assert_operator r["min"], :<=, r["q1"], "min > q1 for #{oxide}"
        assert_operator r["q1"], :<=, r["median"], "q1 > median for #{oxide}"
        assert_operator r["median"], :<=, r["q3"], "median > q3 for #{oxide}"
        assert_operator r["q3"], :<=, r["max"], "q3 > max for #{oxide}"
        assert_operator r["max"], :<=, 100.0, "max > 100 for #{oxide}"
        assert_in_delta (r["q3"] - r["q1"]), r["iqr"], 0.01, "IQR mismatch for #{oxide}"
      end
    end
  end
end
