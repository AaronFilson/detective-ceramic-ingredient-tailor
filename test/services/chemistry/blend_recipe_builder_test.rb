# frozen_string_literal: true

require "test_helper"

module Chemistry
  class BlendRecipeBuilderTest < ActiveSupport::TestCase
    setup do
      @wild_clay = UserSample.create!(
        title: "Puget Glacial Wild Clay",
        material_category: :wild_clay,
        latitude: 47.2529,
        longitude: -122.4443
      )
      @wild_clay.assay_results.create!(
        source_type: :spatial_heuristic_estimate,
        oxides: {
          "SiO2" => 62.0,
          "Al2O3" => 18.0,
          "Fe2O3" => 4.0,
          "CaO" => 2.0,
          "MgO" => 1.0,
          "Na2O" => 1.0,
          "K2O" => 2.0,
          "LOI" => 10.0
        }
      )

      @wood_ash = UserSample.create!(
        title: "Red Alder Wood Ash",
        material_category: :wood_ash
      )
      @wood_ash.assay_results.create!(
        source_type: :verified_lab_xrf,
        oxides: {
          "SiO2" => 12.0,
          "Al2O3" => 3.0,
          "Fe2O3" => 1.0,
          "CaO" => 52.0,
          "MgO" => 6.0,
          "Na2O" => 1.0,
          "K2O" => 6.0,
          "P2O5" => 3.0,
          "LOI" => 16.0
        }
      )

      @granite = UserSample.create!(
        title: "Cascade Feldspathic Granite",
        material_category: :crushed_rock,
        latitude: 47.45,
        longitude: -121.40
      )
      @granite.assay_results.create!(
        source_type: :spatial_heuristic_estimate,
        oxides: {
          "SiO2" => 73.0,
          "Al2O3" => 14.0,
          "Fe2O3" => 1.5,
          "CaO" => 1.0,
          "MgO" => 0.5,
          "Na2O" => 4.2,
          "K2O" => 4.8,
          "LOI" => 1.0
        }
      )
    end

    test "computes 11-step line blend for 2 materials and selects optimal batch" do
      result = BlendRecipeBuilder.call(
        samples: [ @wild_clay, @wood_ash ],
        target_cone: "10",
        surface: "matte"
      )

      assert result.line_blend?
      assert_not result.triaxial?
      assert_equal "10", result.target_cone
      assert_equal "matte", result.surface
      assert_equal 11, result.candidates.size

      # Verify 0/100, 10/90, ..., 100/0 progression
      assert_equal [ 0, 100 ], result.candidates.first.weights.map { |w| w[:percentage] }
      assert_equal [ 100, 0 ], result.candidates.last.weights.map { |w| w[:percentage] }

      result.candidates.each do |candidate|
        assert_equal 100, candidate.weights.sum { |w| w[:percentage] }
        assert_in_delta 100.0, candidate.oxides.values.sum, 0.05
        assert_includes BlendRecipeBuilder::STULL_ZONES, candidate.stull_zone
      end

      # Pure clay is refractory, pure ash is high-flux, optimal should be an intermediate mix
      assert_equal "Underfired / High-Flux", result.candidates.first.stull_zone
      assert_equal "Unfused / Refractory", result.candidates.last.stull_zone

      optimal = result.optimal
      assert_equal result.ranked_candidates.first, optimal
      assert_operator optimal.weights[0][:percentage], :>=, 60
      assert_operator optimal.weights[1][:percentage], :>=, 10
      assert_equal "Matte", optimal.stull_zone
      assert_in_delta 1.0, optimal.umf["flux_total"], 0.01
    end

    test "computes 231-point triaxial simplex grid for 3 materials and finds gloss glaze" do
      result = BlendRecipeBuilder.call(
        samples: [ @wild_clay, @wood_ash, @granite ],
        target_cone: "10",
        surface: "gloss"
      )

      assert result.triaxial?
      assert_not result.line_blend?
      assert_equal 231, result.candidates.size
      assert_equal 12, result.top_candidates.size

      result.candidates.each do |candidate|
        assert_equal 100, candidate.weights.sum { |w| w[:percentage] }
        assert candidate.weights.all? { |w| w[:percentage] >= 0 && (w[:percentage] % 5).zero? }
      end

      optimal = result.optimal
      assert_equal "Gloss", optimal.stull_zone
      assert optimal.band_checks[:sio2], "Expected Cone 10 Gloss optimal SiO2 #{optimal.sio2} in 3.5..5.0"
      assert optimal.band_checks[:al2o3], "Expected Cone 10 Gloss optimal Al2O3 #{optimal.al2o3} in 0.38..0.55"
      assert optimal.band_checks[:si_al], "Expected Cone 10 Gloss optimal Si:Al #{optimal.si_al_ratio} in 7.0..10.0"
      assert_operator optimal.fit_score, :>, 80.0
    end

    test "adapts optimal formulation between Cone 6 Gloss, Cone 6 Matte, Cone 10 Gloss, and Cone 10 Matte" do
      c6_gloss = BlendRecipeBuilder.call(samples: [ @wild_clay, @wood_ash, @granite ], target_cone: "6", surface: "gloss")
      c6_matte = BlendRecipeBuilder.call(samples: [ @wild_clay, @wood_ash, @granite ], target_cone: "6", surface: "matte")
      c10_gloss = BlendRecipeBuilder.call(samples: [ @wild_clay, @wood_ash, @granite ], target_cone: "10", surface: "gloss")
      c10_matte = BlendRecipeBuilder.call(samples: [ @wild_clay, @wood_ash, @granite ], target_cone: "10", surface: "matte")

      # Gloss targets should produce higher Si:Al ratios than Matte targets at the same cone
      assert_operator c6_gloss.optimal.si_al_ratio, :>, c6_matte.optimal.si_al_ratio
      assert_operator c10_gloss.optimal.si_al_ratio, :>, c10_matte.optimal.si_al_ratio

      # Cone 10 Gloss targets higher silica than Cone 6 Gloss
      assert_operator c10_gloss.optimal.sio2, :>=, c6_gloss.optimal.sio2

      assert_equal "Gloss", c6_gloss.optimal.stull_zone
      assert_equal "Matte", c6_matte.optimal.stull_zone
      assert_equal "Gloss", c10_gloss.optimal.stull_zone
      assert_equal "Matte", c10_matte.optimal.stull_zone

      # Local-only Cone 6 blends flag missing boron while preserving clean scoring
      assert c6_gloss.b2o3_missing_cone6?
      assert c6_matte.b2o3_missing_cone6?
      assert_not c10_gloss.b2o3_missing_cone6?
      assert_not c6_gloss.optimal.band_checks.key?(:b2o3)
    end

    test "reformulates 1 wild clay with Whiting and Ferro Frit 3134 into in-band Cone 6 Gloss with B2O3 and balanced COE" do
      whiting = StockMaterialsCatalog.find("whiting")
      frit_3134 = StockMaterialsCatalog.find("ferro_frit_3134")

      result = BlendRecipeBuilder.call(
        samples: [ @wild_clay, whiting, frit_3134 ],
        target_cone: "6",
        surface: "gloss"
      )

      assert result.triaxial?
      assert_not result.b2o3_missing_cone6?

      optimal = result.optimal
      assert_equal "Gloss", optimal.stull_zone
      assert optimal.band_checks[:sio2], "Expected SiO2 #{optimal.sio2} in 3.0..4.2"
      assert optimal.band_checks[:al2o3], "Expected Al2O3 #{optimal.al2o3} in 0.32..0.48"
      assert optimal.band_checks[:si_al], "Expected Si:Al #{optimal.si_al_ratio} in 6.5..9.5"
      assert optimal.band_checks[:flux], "Expected R2O #{optimal.r2o_total} in 0.20..0.45"
      assert optimal.band_checks[:b2o3], "Expected B2O3 #{optimal.b2o3} in 0.12..0.32"
      assert optimal.all_in_band?
      assert_operator optimal.fit_score, :>, 85.0
      assert_operator optimal.minor_oxides["B2O3"], :>, 2.0
      assert_in_delta 100.0, optimal.oxides.values.sum + optimal.minor_oxides.values.sum, 0.05

      assert_not_nil optimal.coe_report
      assert_equal :balanced_fit, optimal.crazing_risk
      assert_includes 5.5..7.4, optimal.coe
    end

    test "blends minor oxides from StockMaterials and UserSample assays including Li2O low-expansion flux" do
      spodumene = StockMaterialsCatalog.find("spodumene")
      neph_sy = StockMaterialsCatalog.find("nepheline_syenite")
      dolomite = StockMaterialsCatalog.find("dolomite")

      li_blend = BlendRecipeBuilder.call(
        samples: [ @wild_clay, spodumene, dolomite ],
        target_cone: "10",
        surface: "matte"
      )
      alkali_blend = BlendRecipeBuilder.call(
        samples: [ @wild_clay, neph_sy, dolomite ],
        target_cone: "10",
        surface: "matte"
      )

      # Pick comparable 50/30/20 candidate to verify direct Li2O vs Na2O/K2O thermal expansion shift
      li_50_30_20 = li_blend.candidates.find { |c| c.weights.map { |w| w[:percentage] } == [ 50, 30, 20 ] }
      na_50_30_20 = alkali_blend.candidates.find { |c| c.weights.map { |w| w[:percentage] } == [ 50, 30, 20 ] }

      assert_operator li_50_30_20.minor_oxides["Li2O"], :>, 1.5
      assert_operator li_50_30_20.li2o, :>, 0.10
      assert_operator li_50_30_20.coe, :<, na_50_30_20.coe

      # Verify minor_oxides stored on a UserSample's AssayResult also blend cleanly
      lithium_pegmatite = UserSample.create!(title: "Black Hills Pegmatite", material_category: :crushed_rock)
      lithium_pegmatite.assay_results.create!(
        source_type: :verified_lab_icpms,
        oxides: {
          "SiO2" => 66.0, "Al2O3" => 22.0, "CaO" => 1.0,
          "Na2O" => 2.5, "K2O" => 3.5, "LOI" => 1.0
        },
        minor_oxides: { "Li2O" => 4.0 }
      )

      peg_result = BlendRecipeBuilder.call(
        samples: [ lithium_pegmatite, StockMaterialsCatalog.find("whiting") ],
        target_cone: "10",
        surface: "gloss"
      )
      half_mix = peg_result.candidates.find { |c| c.weights.map { |w| w[:percentage] } == [ 50, 50 ] }
      assert_in_delta 2.0, half_mix.minor_oxides["Li2O"], 0.1
      assert_operator half_mix.li2o, :>, 0.05
    end

    test "classifies all five Stull zones accurately" do
      assert_equal "Gloss", BlendRecipeBuilder.classify_stull_zone(
        "flux_total" => 1.0,
        "glass_formers" => { "SiO2" => 3.6 },
        "intermediates" => { "Al2O3" => 0.42 },
        "si_al_ratio" => 8.57
      )

      assert_equal "Matte", BlendRecipeBuilder.classify_stull_zone(
        "flux_total" => 1.0,
        "glass_formers" => { "SiO2" => 2.9 },
        "intermediates" => { "Al2O3" => 0.52 },
        "si_al_ratio" => 5.58
      )

      assert_equal "Crazing / High-Silica", BlendRecipeBuilder.classify_stull_zone(
        "flux_total" => 1.0,
        "glass_formers" => { "SiO2" => 4.8 },
        "intermediates" => { "Al2O3" => 0.36 },
        "si_al_ratio" => 13.33
      )

      assert_equal "Unfused / Refractory", BlendRecipeBuilder.classify_stull_zone(
        "flux_total" => 1.0,
        "glass_formers" => { "SiO2" => 8.5 },
        "intermediates" => { "Al2O3" => 1.2 },
        "si_al_ratio" => 7.08
      )

      assert_equal "Underfired / High-Flux", BlendRecipeBuilder.classify_stull_zone(
        "flux_total" => 1.0,
        "glass_formers" => { "SiO2" => 1.2 },
        "intermediates" => { "Al2O3" => 0.15 },
        "si_al_ratio" => 8.0
      )
    end

    test "exports valid glazecalc-export v1 bundle containing both materials and recipe" do
      c6_result = BlendRecipeBuilder.call(
        samples: [ @wild_clay, @wood_ash, @granite ],
        target_cone: "6",
        surface: "gloss"
      )
      export = BlendRecipeBuilder.to_glazecalc_export(c6_result, recipe_title: "Puget Ash Gloss #1")

      assert_equal "glazecalc-export", export["format"]
      assert_equal 1, export["version"]
      assert_not_nil export["exportedAt"]

      materials = export.dig("records", "materials")
      recipes = export.dig("records", "recipes")

      assert_equal 3, materials.size
      assert_equal [ "Puget Glacial Wild Clay", "Red Alder Wood Ash", "Cascade Feldspathic Granite" ],
        materials.map { |m| m["name"] }
      materials.each do |mat|
        total = mat["fields"].sum { |f| f["amount"].to_f } + mat["loi"].to_f
        assert_in_delta 100.0, total, 0.1
      end

      assert_equal 1, recipes.size
      recipe = recipes.first
      assert_equal "Puget Ash Gloss #1", recipe["title"]
      assert_equal "mid", recipe["firing"]
      assert_equal 100, recipe["materials"].sum { |line| line["amount"] }
      assert_includes recipe["notes"], "Cone 6 Gloss"
      assert_includes recipe["notes"], "Predicted COE:"

      # Cone 10 maps to firing: "high"
      c10_result = BlendRecipeBuilder.call(
        samples: [ @wild_clay, @wood_ash ],
        target_cone: "10",
        surface: "matte"
      )
      c10_export = BlendRecipeBuilder.to_glazecalc_export(c10_result)
      assert_equal "high", c10_export.dig("records", "recipes", 0, "firing")
    end

    test "exports valid glaze-vault-export v1 archive containing both materials and recipe" do
      result = BlendRecipeBuilder.call(
        samples: [ @wild_clay, @wood_ash, @granite ],
        target_cone: "10",
        surface: "gloss"
      )
      export = BlendRecipeBuilder.to_glaze_vault_export(result, recipe_title: "Cascade Celadon Test")

      assert_equal "glaze-vault-export", export["format"]
      assert_equal 1, export["version"]
      assert_equal Exporters::GlazeVaultSerializer::APP_VERSION, export["appVersion"]
      assert_not_nil export["exportedAt"]

      assert_equal 3, export["materials"].size
      assert_equal [ "Puget Glacial Wild Clay", "Red Alder Wood Ash", "Cascade Feldspathic Granite" ],
        export["materials"].map { |m| m["name"] }

      assert_equal 1, export["recipes"].size
      recipe = export["recipes"].first
      assert_equal "Cascade Celadon Test", recipe["name"]
      assert_equal "glaze", recipe["type"]
      assert_equal "10", recipe["cone"]
      assert_equal "gloss", recipe["surface"]
      assert_equal 100, recipe["lines"].sum { |line| line["amount"] }
      assert recipe["lines"].all? { |line| line["material"].present? && line["amount"].positive? }
      assert_includes recipe["notes"], "Cone 10 Gloss"
      assert_includes recipe["notes"], "Predicted COE:"
    end

    test "exports StockMaterial items alongside UserSample cleanly in Glazecalc and Glaze Vault bundles" do
      whiting = StockMaterialsCatalog.find("whiting")
      frit_3134 = StockMaterialsCatalog.find("ferro_frit_3134")

      result = BlendRecipeBuilder.call(
        samples: [ @wild_clay, whiting, frit_3134 ],
        target_cone: "6",
        surface: "gloss"
      )

      gc_export = BlendRecipeBuilder.to_glazecalc_export(result, recipe_title: "Puget Cone 6 Clear")
      gc_materials = gc_export.dig("records", "materials")
      assert_equal [ "Puget Glacial Wild Clay", "Whiting (CaCO3)", "Ferro Frit 3134" ], gc_materials.map { |m| m["name"] }
      gc_materials.each do |mat|
        total = mat["fields"].sum { |f| f["amount"].to_f } + mat["loi"].to_f
        assert_in_delta 100.0, total, 0.1
      end
      frit_mat = gc_materials.find { |m| m["name"] == "Ferro Frit 3134" }
      assert_includes frit_mat["fields"].map { |f| f["name"] }, "B2O3"
      assert_equal "studio_stock_catalog", frit_mat.dig("source", "kind")
      assert_includes gc_export.dig("records", "recipes", 0, "notes"), "B2O3"
      assert_includes gc_export.dig("records", "recipes", 0, "notes"), "Predicted COE:"

      gv_export = BlendRecipeBuilder.to_glaze_vault_export(result, recipe_title: "Puget Cone 6 Clear")
      assert_equal 3, gv_export["materials"].size
      gv_frit = gv_export["materials"].find { |m| m["name"] == "Ferro Frit 3134" }
      assert_includes gv_frit["oxides"].map { |o| o["oxide"] }, "B2O3"
      assert_includes Exporters::GlazeVaultSerializer::MATERIAL_CLASSES, gv_frit["class"]
      assert_equal %w[whiting ferro_frit_3134], gv_export.dig("provenance", "stock_keys")
      assert_in_delta result.optimal.coe, gv_export.dig("provenance", "coe"), 0.01
      assert_includes gv_export.dig("recipes", 0, "notes"), "B2O3"
      assert_includes gv_export.dig("recipes", 0, "notes"), "Predicted COE:"
    end

    test "raises ArgumentError for invalid sample counts, duplicates, cone, surface, or missing assays" do
      fourth = UserSample.create!(title: "Fourth Sample", material_category: :other)
      fourth.assay_results.create!(oxides: { "SiO2" => 95.0, "Al2O3" => 4.0, "LOI" => 1.0 })
      whiting = StockMaterialsCatalog.find("whiting")

      assert_raises(ArgumentError) { BlendRecipeBuilder.call(samples: [ @wild_clay ]) }
      assert_raises(ArgumentError) { BlendRecipeBuilder.call(samples: [ @wild_clay, @wood_ash, @granite, fourth ]) }
      assert_raises(ArgumentError) { BlendRecipeBuilder.call(samples: [ @wild_clay, @wild_clay ]) }
      assert_raises(ArgumentError) { BlendRecipeBuilder.call(samples: [ whiting, whiting ]) }
      assert_raises(ArgumentError) { BlendRecipeBuilder.call(samples: [ @wild_clay, @wood_ash ], target_cone: "04") }
      assert_raises(ArgumentError) { BlendRecipeBuilder.call(samples: [ @wild_clay, @wood_ash ], surface: "crystalline") }

      unassayed = UserSample.create!(title: "No Assay", material_category: :wild_clay)
      assert_raises(ArgumentError) { BlendRecipeBuilder.call(samples: [ @wild_clay, unassayed ]) }
    end
  end
end
