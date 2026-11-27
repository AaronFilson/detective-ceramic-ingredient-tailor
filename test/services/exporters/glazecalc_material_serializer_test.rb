# frozen_string_literal: true

require "test_helper"

module Exporters
  class GlazecalcMaterialSerializerTest < ActiveSupport::TestCase
    MOLAR_MASSES = GlazecalcMaterialSerializer::MOLAR_MASSES

    setup do
      @unit = GeologicUnit.create!(
        macrostrat_id: 90101,
        name: "Vashon Drift",
        strat_name: "Vashon Glacial Till",
        age: "Pleistocene",
        lithology: { "major" => [ "clay", "silt" ], "minor" => [ "sand" ] }
      )

      @sample = UserSample.create!(
        title: "Tacoma Bluff Wild Clay",
        material_category: :wild_clay,
        geologic_unit: @unit,
        latitude: 47.2529,
        longitude: -122.4443,
        notes: "Collected from weathered glacial bluff seam"
      )

      @observation = @sample.field_observations.create!(
        vinegar_fizz: :slight,
        slaking_behavior: :fast_disintegration,
        plasticity: :high_plastic,
        raw_color: "gray-brown",
        fired_cone: "6",
        fired_color: "warm brown",
        melt_state: :vitrified_tight,
        shrinkage_percent: 11.5
      )

      @assay = @sample.assay_results.create!(
        source_type: :spatial_heuristic_estimate,
        confidence_score: 0.785,
        oxides: {
          "SiO2" => 62.4,
          "Al2O3" => 18.2,
          "Fe2O3" => 4.1,
          "CaO" => 2.3,
          "MgO" => 1.2,
          "Na2O" => 0.8,
          "K2O" => 1.2,
          "TiO2" => 0.0,
          "P2O5" => 0.0,
          "MnO" => 0.0,
          "LOI" => 9.8
        },
        reasoning_log: [
          "Spatial baseline matched 14 Puget Sound glacial clay assays",
          "Slight vinegar fizz increased CaO (+1.2%) and LOI (+0.9%)"
        ]
      )
    end

    test "serializes exact glazecalc schema with stoichiometric unity and exact 100.00% sum" do
      payload = GlazecalcMaterialSerializer.call(@assay)

      assert_equal "Tacoma Bluff Wild Clay", payload["name"]
      assert_equal "percent", payload["percentmole"]
      assert_equal 100.0, payload["molecularweight"]
      assert_equal 9.8, payload["loi"]
      assert payload["loi"] >= 0.0 && payload["loi"] < 100.0

      # Fired oxides + LOI sum to exact 100.00%
      assert_not payload["oxideAnalysis"].key?("LOI")
      assert_in_delta 100.0, payload["oxideAnalysis"].values.sum + payload["loi"], 0.001
      assert_in_delta 100.0, payload["oxides"].values.sum, 0.001
      assert_equal CeramicOxides::KEYS, payload["oxides"].keys

      # fields contain fired oxides only (no LOI, no zero oxides) and sum + LOI == 100.00%
      field_names = payload["fields"].map { |f| f["name"] }
      assert_not_includes field_names, "LOI"
      assert_not_includes field_names, "TiO2"
      assert_equal %w[SiO2 Al2O3 Fe2O3 CaO MgO Na2O K2O], field_names

      fields_sum = payload["fields"].sum { |f| f["amount"].to_f }
      assert_in_delta 100.0, fields_sum + payload["loi"], 0.001

      # Verify exact stoichiometry: equivalent, formulaweight, amountUnity
      moles_per_g = {
        "CaO" => (2.3 / 100.0) / 56.08,
        "MgO" => (1.2 / 100.0) / 40.30,
        "Na2O" => (0.8 / 100.0) / 61.98,
        "K2O" => (1.2 / 100.0) / 94.20
      }
      expected_equivalent = (1.0 / moles_per_g.values.sum).round(2)
      expected_formulaweight = (expected_equivalent * (1.0 - 9.8 / 100.0)).round(2)

      assert_equal expected_equivalent, payload["equivalent"]
      assert_equal expected_formulaweight, payload["formulaweight"]

      # Verify amountUnity matches (wt_pct / 100 / molar_mass) * equivalent within 1%
      payload["fields"].each do |field|
        oxide = field["name"]
        wt_pct = field["amount"].to_f
        expected_unity = (wt_pct / 100.0 / MOLAR_MASSES.fetch(oxide)) * payload["equivalent"]
        assert_in_delta expected_unity, field["amountUnity"], expected_unity * 0.01,
          "amountUnity mismatch for #{oxide}"
      end

      # Flux unity moles sum to 1.0000
      flux_unity = payload["fields"]
        .select { |f| GlazecalcMaterialSerializer::FLUX_OXIDES.include?(f["name"]) }
        .sum { |f| f["amountUnity"] }
      assert_in_delta 1.0, flux_unity, 0.001

      # rawformula includes fired oxides and LOI
      assert_includes payload["rawformula"], "SiO2 62.40%"
      assert_includes payload["rawformula"], "LOI 9.80%"

      # UMF payload structure
      umf = payload["umf"]
      assert_in_delta 1.0, umf["flux_total"], 0.001
      assert_equal expected_equivalent, umf["equivalent_weight"]
      assert_equal expected_formulaweight, umf["formula_weight"]
      assert_in_delta((62.4 / 60.08) / (18.2 / 101.96), umf["si_al_ratio"], 0.002)
      assert_equal %w[CaO MgO Na2O K2O], umf["fluxes"].keys
      assert_equal %w[Al2O3 Fe2O3 MnO], umf["intermediates"].keys
      assert_equal %w[SiO2 TiO2 P2O5], umf["glass_formers"].keys

      # Source metadata
      source = payload["source"]
      assert_equal "spatial_heuristic_estimate", source["kind"]
      assert_equal "detective-ceramic-ingredient-tailor", source["application"]
      assert_equal @sample.id, source["sample_id"]
      assert_equal @assay.id, source["assay_result_id"]
      assert_in_delta 0.785, source["confidence_score"], 0.001
      assert_in_delta 47.2529, source["coordinates"]["lat"], 0.0001
      assert_in_delta(-122.4443, source["coordinates"]["lng"], 0.0001)
      assert_equal 90101, source["geologic_unit"]["macrostrat_id"]
      assert_not_nil source["generated_at"]

      # Notes (Array of Strings) and relatedTo (Array of Strings)
      assert_kind_of Array, payload["notes"]
      assert payload["notes"].all?(String)
      assert payload["notes"].any? { |n| n.include?("weathered glacial bluff") }
      assert payload["notes"].any? { |n| n.include?("Vashon Drift") }
      assert payload["notes"].any? { |n| n.include?("vinegar fizz: slight") }
      assert payload["notes"].any? { |n| n.include?("Spatial baseline matched 14") }

      assert_kind_of Array, payload["relatedTo"]
      assert_includes payload["relatedTo"], "wild clay"
      assert_includes payload["relatedTo"], "Vashon Drift"
      assert_includes payload["relatedTo"], "clay"
      assert_includes payload["relatedTo"], "silt"
    end

    test "normalizes unnormalized and repeating-decimal oxides to exact 100.00% using largest oxide residual" do
      unnormalized_assay = @sample.assay_results.create!(
        source_type: :verified_lab_xrf,
        oxides: {
          SiO2: 33.3333,
          Al2O3: 33.3333,
          CaO: 33.3333,
          LOI: 0.0
        }
      )

      payload = GlazecalcMaterialSerializer.call(unnormalized_assay)
      assert_equal 0.0, payload["loi"]
      assert_equal 100.0, payload["oxides"].values.sum.round(2)
      assert_equal 100.0, (payload["fields"].sum { |f| f["amount"].to_f } + payload["loi"]).round(2)
      assert_equal 33.34, payload["oxideAnalysis"]["SiO2"]
      assert_equal 33.33, payload["oxideAnalysis"]["Al2O3"]
      assert_equal 33.33, payload["oxideAnalysis"]["CaO"]
      assert_not_includes payload["rawformula"], "LOI"
    end

    test "handles zero-flux materials like pure kaolin without ZeroDivisionError" do
      kaolin_assay = @sample.assay_results.create!(
        source_type: :verified_lab_xrf,
        oxides: { "SiO2" => 46.55, "Al2O3" => 39.50, "LOI" => 13.95 }
      )

      payload = GlazecalcMaterialSerializer.call(kaolin_assay)
      assert_equal 100.0, payload["equivalent"]
      assert_equal 86.05, payload["formulaweight"]
      assert_equal 0.0, payload["umf"]["flux_total"]
      assert_in_delta 2.0, payload["umf"]["si_al_ratio"], 0.005

      payload["fields"].each do |field|
        oxide = field["name"]
        expected = (field["amount"].to_f / 100.0 / MOLAR_MASSES.fetch(oxide)) * payload["equivalent"]
        assert_in_delta expected, field["amountUnity"], 0.0005
      end
    end

    test "caps extreme LOI below 100.0 while keeping exact 100.00% total" do
      extreme_assay = @sample.assay_results.create!(
        source_type: :spatial_heuristic_estimate,
        oxides: { "SiO2" => 0.001, "LOI" => 99.999 }
      )

      payload = GlazecalcMaterialSerializer.call(extreme_assay)
      assert payload["loi"] < 100.0
      assert_equal 99.99, payload["loi"]
      assert_equal 0.01, payload["oxideAnalysis"]["SiO2"]
      assert_equal 100.0, (payload["oxideAnalysis"].values.sum + payload["loi"]).round(2)
    end

    test "accepts UserSample directly and selects its latest AssayResult" do
      newer_assay = @sample.assay_results.create!(
        source_type: :verified_lab_xrf,
        oxides: { "SiO2" => 68.0, "Al2O3" => 18.0, "K2O" => 10.0, "Na2O" => 3.0, "LOI" => 1.0 }
      )

      payload = GlazecalcMaterialSerializer.call(@sample)
      assert_equal newer_assay.id, payload["source"]["assay_result_id"]
      assert_equal "verified_lab_xrf", payload["source"]["kind"]
      assert_equal 68.0, payload["oxideAnalysis"]["SiO2"]
    end

    test "raises ArgumentError when sample has no assay or oxides are empty or LOI-only" do
      bare_sample = UserSample.create!(title: "Unanalyzed Sample")
      assert_raises(ArgumentError) { GlazecalcMaterialSerializer.call(bare_sample) }
      assert_raises(ArgumentError) { GlazecalcMaterialSerializer.call(nil) }
      assert_raises(ArgumentError) { GlazecalcMaterialSerializer.call("invalid") }

      empty_assay = bare_sample.assay_results.create!(oxides: {})
      assert_raises(ArgumentError) { GlazecalcMaterialSerializer.call(empty_assay) }

      loi_only_assay = bare_sample.assay_results.create!(oxides: { "LOI" => 100.0 })
      assert_raises(ArgumentError) { GlazecalcMaterialSerializer.call(loi_only_assay) }
    end

    test "delegates UMF calculation to Chemistry::UmfCalculator when defined" do
      fake_umf = { "fluxes" => { "CaO" => 1.0 }, "flux_total" => 1.0, "si_al_ratio" => 5.5 }
      stub_calc = Module.new do
        define_singleton_method(:call) { |_oxides| fake_umf }
      end

      chemistry_existed = Object.const_defined?(:Chemistry)
      chemistry_mod = chemistry_existed ? Object.const_get(:Chemistry) : Object.const_set(:Chemistry, Module.new)
      prev_calc = chemistry_mod.const_defined?(:UmfCalculator, false) ? chemistry_mod.const_get(:UmfCalculator) : nil
      chemistry_mod.send(:remove_const, :UmfCalculator) if prev_calc
      chemistry_mod.const_set(:UmfCalculator, stub_calc)

      payload = GlazecalcMaterialSerializer.call(@assay)
      assert_equal fake_umf, payload["umf"]
    ensure
      if defined?(chemistry_mod) && chemistry_mod
        chemistry_mod.send(:remove_const, :UmfCalculator) if chemistry_mod.const_defined?(:UmfCalculator, false)
        chemistry_mod.const_set(:UmfCalculator, prev_calc) if prev_calc
        Object.send(:remove_const, :Chemistry) unless chemistry_existed
      end
    end
  end
end
