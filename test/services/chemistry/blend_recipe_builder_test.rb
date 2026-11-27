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
    end

    test "raises ArgumentError for invalid sample counts, duplicates, cone, surface, or missing assays" do
      fourth = UserSample.create!(title: "Fourth Sample", material_category: :other)
      fourth.assay_results.create!(oxides: { "SiO2" => 95.0, "Al2O3" => 4.0, "LOI" => 1.0 })

      assert_raises(ArgumentError) { BlendRecipeBuilder.call(samples: [ @wild_clay ]) }
      assert_raises(ArgumentError) { BlendRecipeBuilder.call(samples: [ @wild_clay, @wood_ash, @granite, fourth ]) }
      assert_raises(ArgumentError) { BlendRecipeBuilder.call(samples: [ @wild_clay, @wild_clay ]) }
      assert_raises(ArgumentError) { BlendRecipeBuilder.call(samples: [ @wild_clay, @wood_ash ], target_cone: "04") }
      assert_raises(ArgumentError) { BlendRecipeBuilder.call(samples: [ @wild_clay, @wood_ash ], surface: "crystalline") }

      unassayed = UserSample.create!(title: "No Assay", material_category: :wild_clay)
      assert_raises(ArgumentError) { BlendRecipeBuilder.call(samples: [ @wild_clay, unassayed ]) }
    end
  end
end
