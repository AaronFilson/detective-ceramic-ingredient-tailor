# frozen_string_literal: true

require "test_helper"

module Exporters
  class GlazeVaultSerializerTest < ActiveSupport::TestCase
    setup do
      @unit = GeologicUnit.create!(
        macrostrat_id: 90202,
        name: "Columbia River Basalt",
        strat_name: "Grande Ronde Basalt",
        age: "Miocene",
        lithology: { "major" => [ "basalt" ], "minor" => [ "andesite" ] }
      )

      @sample = UserSample.create!(
        title: "Puyallup River Red Clay",
        material_category: :wild_clay,
        geologic_unit: @unit,
        latitude: 47.1854,
        longitude: -122.2929,
        notes: "Riverbank alluvial clay seam"
      )

      @observation = @sample.field_observations.create!(
        vinegar_fizz: :none,
        slaking_behavior: :fast_disintegration,
        plasticity: :moderate,
        raw_color: "reddish brown",
        fired_cone: "6",
        fired_color: "terracotta red",
        melt_state: :vitrified_tight,
        shrinkage_percent: 11.50
      )

      @assay = @sample.assay_results.create!(
        source_type: :spatial_heuristic_estimate,
        confidence_score: 0.812,
        oxides: {
          "SiO2" => 58.2,
          "Al2O3" => 16.8,
          "Fe2O3" => 6.9,
          "CaO" => 3.1,
          "MgO" => 2.2,
          "Na2O" => 1.4,
          "K2O" => 1.9,
          "TiO2" => 0.9,
          "LOI" => 8.6
        },
        oxide_ranges: {
          "SiO2" => { "min" => 54.0, "median" => 58.2, "max" => 62.5 },
          "Fe2O3" => { "min" => 4.8, "median" => 6.9, "max" => 8.2 }
        },
        umf_formula: {
          "fluxes" => { "CaO" => 0.36, "MgO" => 0.36, "Na2O" => 0.15, "K2O" => 0.13 },
          "flux_total" => 1.0,
          "si_al_ratio" => 5.88
        },
        reasoning_log: [ "Matched Cascade alluvial deposits", "Terracotta fired color boosted Fe2O3" ]
      )
    end

    test "serializes exact glaze-vault-export v1 schema with material entry, sheet, and full provenance" do
      payload = GlazeVaultSerializer.call(@assay)

      assert_equal "glaze-vault-export", payload["format"]
      assert_equal 1, payload["version"]
      assert_equal "detective-ceramic-ingredient-tailor-1.0", payload["appVersion"]
      assert_not_nil payload["exportedAt"]
      assert_equal [], payload["recipes"]
      assert_equal 1, payload["materials"].length

      material = payload["materials"].first
      assert_equal "Puyallup River Red Clay", material["name"]
      assert_equal "material", material["category"]
      assert_equal "8.60", material["loi"]
      assert_equal "earthenware clay", material["class"]
      assert_includes GlazeVaultSerializer::MATERIAL_CLASSES, material["class"]
      assert_equal 1, material["revision"]
      assert_not_nil material["savedAt"]

      # Oxides array uses { oxide, percent } excluding LOI and summing with loi to 100.00%
      oxide_names = material["oxides"].map { |o| o["oxide"] }
      assert_not_includes oxide_names, "LOI"
      assert_equal %w[SiO2 Al2O3 Fe2O3 CaO MgO Na2O K2O TiO2], oxide_names
      assert_equal "58.20", material["oxides"].first["percent"]

      total = material["oxides"].sum { |o| o["percent"].to_f } + material["loi"].to_f
      assert_in_delta 100.0, total, 0.001

      # Sheet populated from field observation
      assert_equal({ "cone" => "6", "totalShrinkage" => "11.5" }, material["sheet"])

      # Notes is a readable String combining provenance, field tests, and reasoning
      assert_kind_of String, material["notes"]
      assert_includes material["notes"], "Riverbank alluvial clay seam"
      assert_includes material["notes"], "Columbia River Basalt"
      assert_includes material["notes"], "47.18540, -122.29290"
      assert_includes material["notes"], "terracotta red"
      assert_includes material["notes"], "Matched Cascade alluvial deposits"

      # Complete provenance block
      provenance = payload["provenance"]
      assert_equal @sample.id, provenance["sample"]["id"]
      assert_equal "wild_clay", provenance["sample"]["material_category"]
      assert_in_delta 47.1854, provenance["sample"]["latitude"], 0.0001
      assert_in_delta(-122.2929, provenance["sample"]["longitude"], 0.0001)

      assert_equal 90202, provenance["geologic_unit"]["macrostrat_id"]
      assert_equal "Columbia River Basalt", provenance["geologic_unit"]["name"]
      assert_equal "Grande Ronde Basalt", provenance["geologic_unit"]["strat_name"]
      assert_equal "Miocene", provenance["geologic_unit"]["age"]
      assert_equal({ "major" => [ "basalt" ], "minor" => [ "andesite" ] }, provenance["geologic_unit"]["lithology"])

      assert_equal 1, provenance["field_observations"].length
      assert_equal "6", provenance["field_observations"].first["fired_cone"]
      assert_equal 11.5, provenance["field_observations"].first["shrinkage_percent"]

      assay_prov = provenance["assay_result"]
      assert_equal @assay.id, assay_prov["id"]
      assert_equal "spatial_heuristic_estimate", assay_prov["source_type"]
      assert_in_delta 0.812, assay_prov["confidence_score"], 0.001
      assert_equal 58.2, assay_prov["oxides"]["SiO2"]
      assert_equal 54.0, assay_prov["oxide_ranges"]["SiO2"]["min"]
      assert_equal 5.88, assay_prov["umf_formula"]["si_al_ratio"]
      assert_equal 2, assay_prov["reasoning_log"].length
    end

    test "omits sheet when no cone or shrinkage observations exist and computes fallback UMF" do
      sample = UserSample.create!(title: "Buff Stoneware Seam", material_category: :wild_clay)
      assay = sample.assay_results.create!(
        source_type: :spatial_heuristic_estimate,
        oxides: { "SiO2" => 65.0, "Al2O3" => 21.0, "Fe2O3" => 1.6, "CaO" => 1.0, "K2O" => 2.4, "LOI" => 9.0 }
      )

      payload = GlazeVaultSerializer.call(sample)
      material = payload["materials"].first

      assert_not material.key?("sheet")
      assert_equal "stoneware clay", material["class"]
      assert_nil payload["provenance"]["geologic_unit"]
      assert_equal [], payload["provenance"]["field_observations"]
      assert_in_delta 1.0, payload["provenance"]["assay_result"]["umf_formula"]["flux_total"], 0.001
    end

    test "maps material classes accurately across clay, rock, ash, and other profiles" do
      cases = [
        [
          { title: "Cascade Granite Dust", material_category: :crushed_rock },
          { "SiO2" => 71.0, "Al2O3" => 14.5, "K2O" => 5.2, "Na2O" => 3.8, "CaO" => 1.8, "Fe2O3" => 2.5, "LOI" => 1.2 },
          "feldspar"
        ],
        [
          { title: "Nepheline Syenite Crush", material_category: :crushed_rock },
          { "SiO2" => 60.5, "Al2O3" => 23.5, "Na2O" => 9.8, "K2O" => 4.8, "CaO" => 0.7, "LOI" => 0.7 },
          "nepheline syenite"
        ],
        [
          { title: "Quartzite Sand", material_category: :crushed_rock },
          { "SiO2" => 97.5, "Al2O3" => 1.5, "Fe2O3" => 0.5, "LOI" => 0.5 },
          "silica"
        ],
        [
          { title: "Primary White Kaolin", material_category: :wild_clay },
          { "SiO2" => 47.0, "Al2O3" => 38.0, "Fe2O3" => 0.6, "K2O" => 0.4, "LOI" => 14.0 },
          "kaolin"
        ],
        [
          { title: "Alder Wood Ash", material_category: :wood_ash },
          { "SiO2" => 12.0, "Al2O3" => 3.0, "CaO" => 52.0, "MgO" => 6.0, "K2O" => 7.0, "P2O5" => 4.0, "LOI" => 16.0 },
          "other"
        ],
        [
          { title: "Volcanic Bentonite Additive", material_category: :other },
          { "SiO2" => 62.0, "Al2O3" => 19.0, "MgO" => 3.0, "Na2O" => 2.5, "Fe2O3" => 3.5, "LOI" => 10.0 },
          "plasticizer"
        ]
      ]

      cases.each do |sample_attrs, oxides, expected_class|
        sample = UserSample.create!(sample_attrs)
        sample.assay_results.create!(oxides: oxides)

        result = GlazeVaultSerializer.call(sample)
        actual_class = result["materials"].first["class"]
        assert_includes GlazeVaultSerializer::MATERIAL_CLASSES, actual_class
        assert_equal expected_class, actual_class, "Expected #{sample.title} to map to #{expected_class}"
      end
    end

    test "raises ArgumentError when sample has no assay result or invalid oxides" do
      sample = UserSample.create!(title: "Missing Assay")
      assert_raises(ArgumentError) { GlazeVaultSerializer.call(sample) }

      empty_assay = sample.assay_results.create!(oxides: {})
      assert_raises(ArgumentError) { GlazeVaultSerializer.call(empty_assay) }
    end

    test "populates expanded Glaze Vault DataSheet physical fields and observation provenance" do
      sample = UserSample.create!(title: "Willamette Stoneware Body", material_category: :wild_clay)
      sample.field_observations.create!(
        fired_cone: "6",
        water_of_plasticity: 23.5,
        drying_shrinkage_percent: 5.2,
        firing_shrinkage_percent: 6.4,
        boiling_water_absorption_percent: 1.85
      )
      sample.assay_results.create!(
        source_type: :spatial_heuristic_estimate,
        oxides: { "SiO2" => 64.0, "Al2O3" => 21.0, "Fe2O3" => 2.2, "CaO" => 1.0, "K2O" => 2.8, "LOI" => 9.0 }
      )

      payload = GlazeVaultSerializer.call(sample)
      sheet = payload.dig("materials", 0, "sheet")

      assert_equal(
        {
          "cone" => "6",
          "dryingShrinkage" => "5.2",
          "firingShrinkage" => "6.4",
          "totalShrinkage" => "11.6",
          "absorption" => "1.85",
          "waterOfPlasticity" => "23.5"
        },
        sheet
      )

      obs_prov = payload.dig("provenance", "field_observations", 0)
      assert_in_delta 23.5, obs_prov["water_of_plasticity"], 0.001
      assert_in_delta 5.2, obs_prov["drying_shrinkage_percent"], 0.001
      assert_in_delta 6.4, obs_prov["firing_shrinkage_percent"], 0.001
      assert_in_delta 1.85, obs_prov["boiling_water_absorption_percent"], 0.001
    end

    test "prefers explicit shrinkage_percent for totalShrinkage and merges latest values across observations" do
      sample = UserSample.create!(title: "Multi-Test Clay", material_category: :wild_clay)
      sample.field_observations.create!(
        water_of_plasticity: 25.0,
        drying_shrinkage_percent: 6.0
      )
      sample.field_observations.create!(
        fired_cone: "10",
        firing_shrinkage_percent: 6.5,
        shrinkage_percent: 12.8,
        boiling_water_absorption_percent: 0.75
      )
      sample.assay_results.create!(
        source_type: :spatial_heuristic_estimate,
        oxides: { "SiO2" => 65.0, "Al2O3" => 22.0, "Fe2O3" => 1.5, "CaO" => 0.8, "K2O" => 2.2, "LOI" => 8.5 }
      )

      payload = GlazeVaultSerializer.call(sample)
      sheet = payload.dig("materials", 0, "sheet")

      assert_equal "10", sheet["cone"]
      assert_equal "6", sheet["dryingShrinkage"]
      assert_equal "6.5", sheet["firingShrinkage"]
      assert_equal "12.8", sheet["totalShrinkage"]
      assert_equal "0.75", sheet["absorption"]
      assert_equal "25", sheet["waterOfPlasticity"]
      assert_equal 2, payload.dig("provenance", "field_observations").length
    end

    test "exports minor ceramic oxides summing to 100.00%, provenance trace elements, and hazard notes" do
      sample = UserSample.create!(title: "Black Hills Spodumene Pegmatite", material_category: :crushed_rock)
      sample.assay_results.create!(
        source_type: :verified_lab_xrf,
        analysis_method: "pxrf",
        oxides: {
          "SiO2" => 66.0, "Al2O3" => 18.5, "K2O" => 7.5, "Na2O" => 3.0,
          "CaO" => 1.0, "Fe2O3" => 1.0, "LOI" => 3.0
        },
        minor_oxides: { "Li2O" => 2.4, "SrO" => 0.6, "BaO" => 2.5, "SO3" => 0.4 },
        trace_elements_ppm: { "Rb" => 580.0, "Pb" => 180.0, "U" => 65.0 }
      )

      payload = GlazeVaultSerializer.call(sample)
      material = payload["materials"].first
      oxide_names = material["oxides"].map { |o| o["oxide"] }

      assert_includes oxide_names, "Li2O"
      assert_includes oxide_names, "SrO"
      assert_includes oxide_names, "BaO"
      assert_not_includes oxide_names, "SO3"

      total = material["oxides"].sum { |o| o["percent"].to_f } + material["loi"].to_f
      assert_in_delta 100.0, total, 0.001

      assay_prov = payload.dig("provenance", "assay_result")
      assert_equal "pxrf", assay_prov["analysis_method"]
      assert_in_delta 2.4, assay_prov.dig("minor_oxides", "Li2O"), 0.001
      assert_in_delta 580.0, assay_prov.dig("trace_elements_ppm", "Rb"), 0.001
      assert_in_delta 180.0, assay_prov.dig("trace_elements_ppm", "Pb"), 0.001
      assert assay_prov.dig("umf_formula", "fluxes").key?("Li2O")

      assert_includes material["notes"], "[HAZARD DANGER]"
      assert_includes material["notes"], "Lead"
      assert_includes material["notes"], "Barium"
      assert_includes material["notes"], "Radioactive"
      assert_includes material["notes"], "Hard-Rock"
    end
  end
end
