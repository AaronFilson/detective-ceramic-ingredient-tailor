# frozen_string_literal: true

require "test_helper"

module Chemistry
  class HazardScreenerServiceTest < ActiveSupport::TestCase
    setup do
      @clean_sample = UserSample.create!(
        title: "Clean Glacial Stoneware Clay",
        material_category: :wild_clay
      )
      @clean_assay = @clean_sample.assay_results.create!(
        source_type: :verified_lab_xrf,
        analysis_method: "lab_xrf",
        oxides: {
          "SiO2" => 64.0, "Al2O3" => 21.0, "Fe2O3" => 2.5, "CaO" => 1.2,
          "MgO" => 1.0, "Na2O" => 0.8, "K2O" => 2.5, "TiO2" => 0.9,
          "P2O5" => 0.1, "MnO" => 0.05, "LOI" => 5.95
        },
        minor_oxides: {},
        trace_elements_ppm: { "As" => 8.0, "Pb" => 22.0, "Cd" => 0.5, "U" => 3.0, "Th" => 11.0, "S" => 1000.0 }
      )
    end

    test "returns clean all-clear result when no hazard thresholds are exceeded" do
      result = HazardScreenerService.call(
        assay_result: @clean_assay,
        user_sample: @clean_sample,
        nearby_minerals: [],
        nearby_xrd: {}
      )

      assert_empty result.alerts
      assert_nil result.highest_severity
      assert_not result.food_safe_caution?
      assert_nil result.k_rb_ratio
      assert_includes result.summary, "No studio health"
    end

    test "flags toxic heavy metals As, Pb, Cd, and radioactive U/Th as danger with food-safe caution" do
      assay = @clean_sample.assay_results.create!(
        source_type: :verified_lab_icpms,
        oxides: @clean_assay.oxides,
        trace_elements_ppm: {
          "As" => 75.0,
          "Pb" => 240.0,
          "Cd" => 18.0,
          "U" => 85.0,
          "Th" => 62.0
        }
      )

      result = HazardScreenerService.call(
        assay_result: assay,
        user_sample: @clean_sample,
        nearby_minerals: [],
        nearby_xrd: {}
      )

      codes = result.alerts.map { |a| a[:code] }
      assert_includes codes, "toxic_arsenic"
      assert_includes codes, "toxic_lead"
      assert_includes codes, "toxic_cadmium"
      assert_includes codes, "radioactive_minerals"
      assert_equal :danger, result.highest_severity
      assert result.food_safe_caution?
      assert result.alerts.all? { |a| a[:severity] == :danger && a[:category] == :health }
    end

    test "flags Barium, Chromium, Manganese, Copper, Cobalt/Nickel, and Vanadium oxide thresholds" do
      assay = @clean_sample.assay_results.create!(
        source_type: :verified_lab_xrf,
        oxides: @clean_assay.oxides.merge("MnO" => 4.2),
        minor_oxides: {
          "BaO" => 3.1,
          "Cr2O3" => 0.8,
          "CuO" => 3.5,
          "CoO" => 0.7,
          "NiO" => 0.6,
          "V2O5" => 0.9
        }
      )

      result = HazardScreenerService.call(
        assay_result: assay,
        user_sample: @clean_sample,
        nearby_minerals: [],
        nearby_xrd: {}
      )

      by_code = result.alerts.index_by { |a| a[:code] }
      assert_equal :danger, by_code.dig("barium_toxicity", :severity)
      assert_equal :danger, by_code.dig("vanadium_toxicity", :severity)
      assert_equal :warning, by_code.dig("chromium_hazard", :severity)
      assert_equal :warning, by_code.dig("manganese_hazard", :severity)
      assert_equal :warning, by_code.dig("copper_leaching", :severity)
      assert_equal :warning, by_code.dig("cobalt_nickel_sensitizer", :severity)
      assert result.food_safe_caution?

      # Danger alerts sort ahead of warning alerts
      severities = result.alerts.map { |a| a[:severity] }
      assert_equal severities.index(:danger), 0
      assert severities.rindex(:danger) < severities.index(:warning)
    end

    test "flags Fluorine HF kiln gas and Sulfide SO2 pinholing from chemistry and nearby minerals" do
      assay = @clean_sample.assay_results.create!(
        source_type: :verified_lab_xrf,
        oxides: @clean_assay.oxides,
        minor_oxides: { "F" => 0.35, "SO3" => 0.45 }
      )

      chem_result = HazardScreenerService.call(
        assay_result: assay,
        user_sample: @clean_sample,
        nearby_minerals: [],
        nearby_xrd: {}
      )
      chem_codes = chem_result.alerts.index_by { |a| a[:code] }
      assert_equal :danger, chem_codes.dig("fluorine_hf_gas", :severity)
      assert_equal :kiln, chem_codes.dig("fluorine_hf_gas", :category)
      assert_equal :warning, chem_codes.dig("sulfide_degassing", :severity)
      assert_includes chem_codes.dig("sulfide_degassing", :recommendation), "800°C"

      # Mineral-occurrence triggers (lepidolite, pyrite, barite, chromite, monazite, pyrolusite)
      mineral_occ = MineralOccurrence.new(
        source: "usgs_mrds",
        name: "Cascade Pegmatite Prospect",
        commodities: [ "barite", "chromite" ],
        minerals: [ "lepidolite", "pyrite", "monazite", "pyrolusite" ]
      )
      min_result = HazardScreenerService.call(
        assay_result: @clean_assay,
        user_sample: @clean_sample,
        nearby_minerals: [ mineral_occ ],
        nearby_xrd: {}
      )
      min_codes = min_result.alerts.map { |a| a[:code] }
      assert_includes min_codes, "barium_toxicity"
      assert_includes min_codes, "radioactive_minerals"
      assert_includes min_codes, "chromium_hazard"
      assert_includes min_codes, "manganese_hazard"
      assert_includes min_codes, "fluorine_hf_gas"
      assert_includes min_codes, "sulfide_degassing"
    end

    test "flags sulfur ppm above 2000 ppm without false-triggering at 1000 ppm" do
      high_s_assay = @clean_sample.assay_results.create!(
        source_type: :verified_lab_xrf,
        oxides: @clean_assay.oxides,
        trace_elements_ppm: { "S" => 2600.0 }
      )

      result = HazardScreenerService.call(
        assay_result: high_s_assay,
        user_sample: @clean_sample,
        nearby_minerals: [],
        nearby_xrd: {}
      )

      assert_includes result.alerts.map { |a| a[:code] }, "sulfide_degassing"
    end

    test "emits hard-rock crystalline silica, thermal-shock, and tramp-iron guidance" do
      unit = GeologicUnit.create!(
        macrostrat_id: 98101,
        name: "Index Batholith",
        lithology: { "major" => [ "granite", "pegmatite" ] }
      )
      rock_sample = UserSample.create!(
        title: "Index Crushed Pegmatite",
        material_category: :crushed_rock,
        geologic_unit: unit
      )

      result = HazardScreenerService.call(
        assay_result: nil,
        user_sample: rock_sample,
        nearby_minerals: [],
        nearby_xrd: {}
      )

      alert = result.alerts.find { |a| a[:code] == "hard_rock_silica_processing" }
      assert_not_nil alert
      assert_equal :warning, alert[:severity]
      assert_equal :processing, alert[:category]
      assert_includes alert[:detail].downcase, "respirable crystalline silica"
      assert_includes alert[:recommendation].downcase, "wet ball-mill"
      assert_includes alert[:recommendation], "600°C"
      assert_includes alert[:recommendation].downcase, "magnet"
    end

    test "emits pXRF blind spot and computes LCT pegmatite K/Rb pathfinder signal" do
      # K2O = 6.0% -> K = 49,806 ppm; Rb = 450 ppm -> K/Rb = 110.7 (< 160 -> LCT lithium signal!)
      pegmatite_assay = @clean_sample.assay_results.create!(
        source_type: :verified_lab_xrf,
        analysis_method: "pxrf",
        oxides: @clean_assay.oxides.merge("K2O" => 6.0),
        trace_elements_ppm: { "Rb" => 450.0, "Cs" => 85.0, "Nb" => 65.0 }
      )

      result = HazardScreenerService.call(
        assay_result: pegmatite_assay,
        user_sample: @clean_sample,
        nearby_minerals: [],
        nearby_xrd: {}
      )

      assert_in_delta 110.7, result.k_rb_ratio, 0.2

      pxrf_alert = result.alerts.find { |a| a[:code] == "pxrf_light_element_blind_spot" }
      assert_not_nil pxrf_alert
      assert_equal :info, pxrf_alert[:severity]
      assert_includes pxrf_alert[:detail], "Li2O"
      assert_includes pxrf_alert[:detail], "B2O3"
      assert_includes pxrf_alert[:detail], "LOI"

      lct_alert = result.alerts.find { |a| a[:code] == "lct_pegmatite_pathfinder" }
      assert_not_nil lct_alert
      assert_equal :info, lct_alert[:severity]
      assert_includes lct_alert[:detail], "Fractionated LCT Pegmatite Pathfinder Signal"
      assert_includes lct_alert[:detail], "110.7"
      assert_includes lct_alert[:detail], "Li2O"

      # Normal unfractionated granite (K2O = 6.0%, Rb = 200 ppm -> K/Rb = 249.0 >= 160) does not trigger LCT alert
      normal_assay = @clean_sample.assay_results.create!(
        source_type: :verified_lab_xrf,
        analysis_method: "lab_xrf",
        oxides: @clean_assay.oxides.merge("K2O" => 6.0),
        trace_elements_ppm: { "Rb" => 200.0 }
      )
      normal_result = HazardScreenerService.call(
        assay_result: normal_assay,
        user_sample: @clean_sample,
        nearby_minerals: [],
        nearby_xrd: {}
      )
      assert_in_delta 249.0, normal_result.k_rb_ratio, 0.2
      assert_not_includes normal_result.alerts.map { |a| a[:code] }, "lct_pegmatite_pathfinder"
    end

    test "screens XRD clay mineralogy for high smectite, high quartz, and calcite" do
      result = HazardScreenerService.call(
        assay_result: @clean_assay,
        user_sample: @clean_sample,
        nearby_minerals: [],
        nearby_xrd: { "smectite" => 22.5, "quartz" => 48.0, "calcite" => 7.5 }
      )

      codes = result.alerts.map { |a| a[:code] }
      assert_includes codes, "xrd_high_smectite"
      assert_includes codes, "xrd_high_quartz"
      assert_includes codes, "xrd_high_calcite"
      assert_equal :warning, result.highest_severity
      assert result.alerts.all? { |a| a[:category] == :mineralogy }
    end

    test "auto-resolves nearby PostGIS MineralOccurrence and DS-801 XRD mineralogy when coordinates exist" do
      MineralOccurrence.create!(
        source: "usgs_mrds",
        external_id: "mrds-hazard-test-1",
        name: "Fluorite Vein",
        commodities: [ "fluorine" ],
        minerals: [ "fluorite" ],
        latitude: 47.6100,
        longitude: -120.6600
      )
      ReferenceAssay.create!(
        source: "usgs_ds801",
        external_id: "ds801-hazard-test-1",
        rock_type: "soil",
        oxides: { "SiO2" => 60.0, "Al2O3" => 15.0 },
        xrd_mineralogy: { "smectite" => 18.0, "calcite" => 6.0 },
        latitude: 47.6200,
        longitude: -120.6500
      )
      geo_sample = UserSample.create!(
        title: "Wenatchee Clay Test",
        material_category: :wild_clay,
        latitude: 47.6150,
        longitude: -120.6550
      )

      result = HazardScreenerService.call(assay_result: @clean_assay, user_sample: geo_sample)
      codes = result.alerts.map { |a| a[:code] }
      assert_includes codes, "fluorine_hf_gas"
      assert_includes codes, "xrd_high_smectite"
      assert_includes codes, "xrd_high_calcite"
    end
  end
end
