# frozen_string_literal: true

require "test_helper"

module Inference
  class BaselineEstimatorServiceTest < ActiveSupport::TestCase
    TACOMA_LAT = 47.2529
    TACOMA_LNG = -122.4443

    setup do
      ReferenceAssay.delete_all
    end

    test "Tier 1: uses 15km local match when >= 5 matching assays exist within 15km" do
      # Create 5 glacial_clay assays within ~1-5 km of Tacoma plus 1 basalt nearby and 1 distant clay
      sio2_values = [56.0, 58.0, 60.0, 62.0, 64.0]
      created_ids = sio2_values.each_with_index.map do |sio2, idx|
        create_assay!(
          external_id: "LOCAL-CLAY-#{idx}",
          rock_type: "glacial_clay",
          lat: TACOMA_LAT + (idx * 0.005),
          lng: TACOMA_LNG + (idx * 0.005),
          oxides: standard_clay_oxides(sio2: sio2, al2o3: 16.0 + idx, fe2o3: 5.0 + (idx * 0.5))
        ).id
      end

      # Unrelated nearby rock type (should be excluded by wild_clay / glacial filter)
      basalt = create_assay!(
        external_id: "LOCAL-BASALT-1",
        rock_type: "basalt",
        lat: TACOMA_LAT + 0.002,
        lng: TACOMA_LNG - 0.002,
        oxides: standard_basalt_oxides
      )

      unit = GeologicUnit.create!(
        macrostrat_id: 51001,
        name: "Vashon Drift",
        lithology: { "raw" => "Major:{glacial till, clay}" }
      )
      sample = UserSample.create!(
        title: "Point Defiance Bluff Clay",
        material_category: :wild_clay,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG,
        geologic_unit: unit
      )

      result = Inference::BaselineEstimatorService.call(sample)

      assert_equal :local_15km, result.strategy
      assert_equal 15_000, result.search_radius_meters
      assert_equal 5, result.sample_count
      assert_equal created_ids.sort, result.matched_assay_ids.sort
      assert_not_includes result.matched_assay_ids, basalt.id

      # Verify exact percentile / IQR math on [56, 58, 60, 62, 64]
      sio2_range = result.oxide_ranges["SiO2"]
      assert_in_delta 56.0, sio2_range["min"], 0.001
      assert_in_delta 58.0, sio2_range["q1"], 0.001
      assert_in_delta 60.0, sio2_range["median"], 0.001
      assert_in_delta 62.0, sio2_range["q3"], 0.001
      assert_in_delta 64.0, sio2_range["max"], 0.001
      assert_in_delta 4.0, sio2_range["iqr"], 0.001

      assert_equal CeramicOxides::KEYS, result.oxides.keys
      assert_equal CeramicOxides::KEYS, result.oxide_ranges.keys
      assert_in_delta 100.0, result.oxides.values.sum, 0.01
      assert_operator result.confidence_score, :>, 0.65
      assert_operator result.confidence_score, :<=, 1.0
      assert result.reasoning_log.any? { |entry| entry.include?("15 km") }
    end

    test "Tier 2: falls back to 50km regional match when < 5 local assays exist within 15km" do
      # Only 3 assays within 15 km
      3.times do |idx|
        create_assay!(
          external_id: "NEAR-CLAY-#{idx}",
          rock_type: "glacial_clay",
          lat: TACOMA_LAT + (idx * 0.01),
          lng: TACOMA_LNG,
          oxides: standard_clay_oxides(sio2: 58.0 + idx)
        )
      end

      # 3 more matching assays between 20 km and 40 km
      [47.48, 47.55, 47.05].each_with_index do |lat, idx|
        create_assay!(
          external_id: "REGIONAL-CLAY-#{idx}",
          rock_type: "alluvial_clay",
          lat: lat,
          lng: TACOMA_LNG,
          oxides: standard_clay_oxides(sio2: 60.0 + idx)
        )
      end

      sample = UserSample.create!(
        title: "Puget Sound Clay",
        material_category: :wild_clay,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG
      )

      result = Inference::BaselineEstimatorService.call(sample)

      assert_equal :regional_50km, result.strategy
      assert_equal 50_000, result.search_radius_meters
      assert_equal 6, result.sample_count
      assert_in_delta 100.0, result.oxides.values.sum, 0.01
      assert result.reasoning_log.any? { |entry| entry.include?("expanding to 50 km") }
      assert result.reasoning_log.any? { |entry| entry.include?("Tier 2 hit") }
    end

    test "Tier 3: falls back to 50km unfiltered match when < 5 lithology/category matches exist within 50km" do
      # 5 glacial_clay assays within 50km, only 1 andesite
      5.times do |idx|
        create_assay!(
          external_id: "UNFILT-CLAY-#{idx}",
          rock_type: "glacial_clay",
          lat: TACOMA_LAT + (idx * 0.02),
          lng: TACOMA_LNG,
          oxides: standard_clay_oxides(sio2: 58.0 + idx)
        )
      end
      create_assay!(
        external_id: "UNFILT-ANDESITE-1",
        rock_type: "andesite",
        lat: TACOMA_LAT + 0.03,
        lng: TACOMA_LNG + 0.03,
        oxides: standard_basalt_oxides
      )

      sample = UserSample.create!(
        title: "Local Crushed Stone",
        material_category: :crushed_rock,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG
      )

      result = Inference::BaselineEstimatorService.call(sample)

      assert_equal :regional_50km_unfiltered, result.strategy
      assert_equal 50_000, result.search_radius_meters
      assert_equal 6, result.sample_count
      assert_in_delta 100.0, result.oxides.values.sum, 0.01
      assert result.reasoning_log.any? { |entry| entry.include?("Tier 3 hit") }
    end

    test "Tier 4: falls back to global lithology/category match when no spatial cluster meets threshold" do
      # Distant kaolin assays (far from ocean/desert pin)
      kaolin_a = create_assay!(
        external_id: "KAOLIN-A",
        rock_type: "kaolin_clay",
        lat: 47.5580,
        lng: -117.0780,
        oxides: {
          "SiO2" => 47.8, "Al2O3" => 35.6, "Fe2O3" => 1.05, "CaO" => 0.25,
          "MgO" => 0.30, "Na2O" => 0.18, "K2O" => 0.75, "TiO2" => 1.15,
          "P2O5" => 0.08, "MnO" => 0.02, "LOI" => 12.82
        }
      )
      kaolin_b = create_assay!(
        external_id: "KAOLIN-B",
        rock_type: "kaolin_clay",
        lat: 32.9815,
        lng: -82.8101,
        oxides: {
          "SiO2" => 45.6, "Al2O3" => 38.4, "Fe2O3" => 0.55, "CaO" => 0.12,
          "MgO" => 0.15, "Na2O" => 0.08, "K2O" => 0.20, "TiO2" => 1.45,
          "P2O5" => 0.05, "MnO" => 0.01, "LOI" => 13.39
        }
      )
      # Unrelated global basalt should not contaminate kaolin match
      create_assay!(
        external_id: "GLOBAL-BASALT",
        rock_type: "basalt",
        lat: 45.7054,
        lng: -121.5215,
        oxides: standard_basalt_oxides
      )

      unit = GeologicUnit.create!(
        macrostrat_id: 51002,
        name: "Residual Kaolin Bed",
        lithology: { "raw" => "kaolin" }
      )
      # Pin in remote Nevada desert with no assays within 50km
      sample = UserSample.create!(
        title: "Remote Kaolin Pocket",
        material_category: :wild_clay,
        latitude: 39.5,
        longitude: -117.0,
        geologic_unit: unit
      )

      result = Inference::BaselineEstimatorService.call(sample)

      assert_equal :lithology_global, result.strategy
      assert_nil result.search_radius_meters
      assert_equal 2, result.sample_count
      assert_equal [kaolin_a.id, kaolin_b.id].sort, result.matched_assay_ids.sort
      assert_operator result.oxides["Al2O3"], :>, 35.0
      assert_in_delta 100.0, result.oxides.values.sum, 0.01
      assert result.reasoning_log.any? { |entry| entry.include?("Tier 4 hit") }
    end

    test "Tier 5: falls back to realistic category defaults on empty DB or ocean pin" do
      %i[wild_clay crushed_rock wood_ash other].each do |category|
        sample = UserSample.create!(
          title: "Ocean #{category}",
          material_category: category,
          latitude: 0.0,
          longitude: 0.0
        )

        result = Inference::BaselineEstimatorService.call(sample)

        assert_equal :category_default, result.strategy
        assert_nil result.search_radius_meters
        assert_equal 0, result.sample_count
        assert_equal [], result.matched_assay_ids
        assert_equal CeramicOxides::KEYS, result.oxides.keys
        assert_equal CeramicOxides::KEYS, result.oxide_ranges.keys
        assert_in_delta 100.0, result.oxides.values.sum, 0.01
        assert_operator result.confidence_score, :<=, 0.20
        assert_operator result.confidence_score, :>, 0.0
        assert result.reasoning_log.any? { |entry| entry.include?("Tier 5 fallback") }
      end

      # Verify wood_ash default has distinctly high CaO and K2O
      ash_sample = UserSample.create!(title: "Oak Ash", material_category: :wood_ash, latitude: TACOMA_LAT, longitude: TACOMA_LNG)
      ash_result = Inference::BaselineEstimatorService.call(ash_sample)
      assert_operator ash_result.oxides["CaO"], :>, 35.0
      assert_operator ash_result.oxides["K2O"], :>, 5.0
    end

    test "Tacoma WA (47.2529, -122.4443) wild_clay works against seeded PNW assays" do
      seed_csv = Rails.root.join("db/seeds/sample_assays.csv")
      Ingestion::UsgsCsvImporter.new(seed_csv).call

      unit = GeologicUnit.create!(
        macrostrat_id: 51010,
        name: "Vashon Drift",
        strat_name: "Fraser Glaciation",
        age: "Pleistocene",
        lithology: { "raw" => "Major:{till, glacial drift}, Minor:{clay, silt}" }
      )
      sample = UserSample.create!(
        title: "Tacoma Narrows Glacial Clay",
        material_category: :wild_clay,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG,
        geologic_unit: unit
      )

      result = Inference::BaselineEstimatorService.call(sample)

      # Seed CSV has 4 clay assays within 15km and 13+ within 50km of Tacoma
      assert_equal :regional_50km, result.strategy
      assert_equal 50_000, result.search_radius_meters
      assert_operator result.sample_count, :>=, 10
      assert_in_delta 100.0, result.oxides.values.sum, 0.01

      # Realistic Puget Sound glacial/alluvial stoneware clay chemistry
      assert_in_delta 58.5, result.oxides["SiO2"], 3.0
      assert_in_delta 17.5, result.oxides["Al2O3"], 2.0
      assert_in_delta 6.3, result.oxides["Fe2O3"], 1.5
      assert_in_delta 3.2, result.oxides["CaO"], 1.5
      assert_operator result.confidence_score, :>, 0.60
      assert_operator result.confidence_score, :<, 0.95

      # Every oxide range satisfies min <= q1 <= median <= q3 <= max and iqr == q3 - q1
      CeramicOxides::KEYS.each do |key|
        r = result.oxide_ranges[key]
        assert_operator r["min"], :<=, r["q1"]
        assert_operator r["q1"], :<=, r["median"]
        assert_operator r["median"], :<=, r["q3"]
        assert_operator r["q3"], :<=, r["max"]
        assert_in_delta r["q3"] - r["q1"], r["iqr"], 0.002
      end
    end

    test "linear interpolation computes exact q1, median, q3, and iqr for even-length datasets" do
      # 4 assays with SiO2 = [10, 20, 30, 40] -> q1=17.5, median=25.0, q3=32.5, iqr=15.0
      [10.0, 20.0, 30.0, 40.0].each_with_index do |sio2, idx|
        create_assay!(
          external_id: "INTERP-#{idx}",
          rock_type: "bentonite",
          lat: 10.0 + idx,
          lng: 10.0,
          oxides: {
            "SiO2" => sio2, "Al2O3" => 100.0 - sio2,
            "Fe2O3" => 0.0, "CaO" => 0.0, "MgO" => 0.0, "Na2O" => 0.0,
            "K2O" => 0.0, "TiO2" => 0.0, "P2O5" => 0.0, "MnO" => 0.0, "LOI" => 0.0
          }
        )
      end

      unit = GeologicUnit.create!(
        macrostrat_id: 51020,
        name: "Bentonite Seam",
        lithology: { "raw" => "bentonite" }
      )
      sample = UserSample.create!(
        title: "Custom Bentonite",
        material_category: :wild_clay,
        geologic_unit: unit
      )

      result = Inference::BaselineEstimatorService.call(sample)

      assert_equal :lithology_global, result.strategy
      assert_equal 4, result.sample_count

      sio2 = result.oxide_ranges["SiO2"]
      assert_in_delta 10.0, sio2["min"], 0.001
      assert_in_delta 17.5, sio2["q1"], 0.001
      assert_in_delta 25.0, sio2["median"], 0.001
      assert_in_delta 32.5, sio2["q3"], 0.001
      assert_in_delta 40.0, sio2["max"], 0.001
      assert_in_delta 15.0, sio2["iqr"], 0.001
      assert_in_delta 100.0, result.oxides.values.sum, 0.01
    end

    test "confidence score orders 15km > 50km > lithology_global > category_default" do
      # Populate 5 tight assays around Tacoma
      5.times do |idx|
        create_assay!(
          external_id: "CONF-LOCAL-#{idx}",
          rock_type: "glacial_clay",
          lat: TACOMA_LAT + (idx * 0.005),
          lng: TACOMA_LNG,
          oxides: standard_clay_oxides(sio2: 59.0 + (idx * 0.2))
        )
      end

      local_sample = UserSample.create!(
        title: "Local",
        material_category: :wild_clay,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG
      )
      local_result = Inference::BaselineEstimatorService.call(local_sample)

      # Move 30km south so the 5 assays are in 50km tier instead of 15km
      regional_sample = UserSample.create!(
        title: "Regional",
        material_category: :wild_clay,
        latitude: TACOMA_LAT - 0.25,
        longitude: TACOMA_LNG
      )
      regional_result = Inference::BaselineEstimatorService.call(regional_sample)

      # Far away -> global lithology/category tier
      global_sample = UserSample.create!(
        title: "Global",
        material_category: :wild_clay,
        latitude: 35.0,
        longitude: -110.0
      )
      global_result = Inference::BaselineEstimatorService.call(global_sample)

      # Wood ash with no assays -> category default
      default_sample = UserSample.create!(
        title: "Default",
        material_category: :wood_ash,
        latitude: 35.0,
        longitude: -110.0
      )
      default_result = Inference::BaselineEstimatorService.call(default_sample)

      assert_equal :local_15km, local_result.strategy
      assert_equal :regional_50km, regional_result.strategy
      assert_equal :lithology_global, global_result.strategy
      assert_equal :category_default, default_result.strategy

      assert_operator local_result.confidence_score, :>, regional_result.confidence_score
      assert_operator regional_result.confidence_score, :>, global_result.confidence_score
      assert_operator global_result.confidence_score, :>, default_result.confidence_score
    end

    test "wild_clay sample on basalt bedrock still filters for clay assays rather than basalt" do
      5.times do |idx|
        create_assay!(
          external_id: "COMPAT-CLAY-#{idx}",
          rock_type: "alluvial_clay",
          lat: TACOMA_LAT + (idx * 0.005),
          lng: TACOMA_LNG,
          oxides: standard_clay_oxides(sio2: 60.0)
        )
        create_assay!(
          external_id: "COMPAT-BASALT-#{idx}",
          rock_type: "basalt",
          lat: TACOMA_LAT + (idx * 0.005),
          lng: TACOMA_LNG + 0.005,
          oxides: standard_basalt_oxides
        )
      end

      basalt_unit = GeologicUnit.create!(
        macrostrat_id: 51030,
        name: "Wanapum Basalt",
        lithology: { "raw" => "Major:{Basalt}" }
      )

      clay_sample = UserSample.create!(
        title: "Clay Pocket on Basalt",
        material_category: :wild_clay,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG,
        geologic_unit: basalt_unit
      )
      clay_result = Inference::BaselineEstimatorService.call(clay_sample)
      assert_equal :local_15km, clay_result.strategy
      assert_operator clay_result.oxides["SiO2"], :>, 57.0
      assert_operator clay_result.oxides["Fe2O3"], :<, 8.0

      rock_sample = UserSample.create!(
        title: "Crushed Wanapum Basalt",
        material_category: :crushed_rock,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG,
        geologic_unit: basalt_unit
      )
      rock_result = Inference::BaselineEstimatorService.call(rock_sample)
      assert_equal :local_15km, rock_result.strategy
      assert_in_delta 51.5, rock_result.oxides["SiO2"], 0.5
      assert_in_delta 13.0, rock_result.oxides["Fe2O3"], 0.5
    end

    private

    def create_assay!(external_id:, rock_type:, lat:, lng:, oxides:)
      ReferenceAssay.create!(
        source: "test_seed",
        external_id: external_id,
        rock_type: rock_type,
        latitude: lat,
        longitude: lng,
        oxides: oxides
      )
    end

    def standard_clay_oxides(sio2: 59.0, al2o3: 17.5, fe2o3: 6.0)
      remaining = 100.0 - sio2 - al2o3 - fe2o3
      {
        "SiO2" => sio2,
        "Al2O3" => al2o3,
        "Fe2O3" => fe2o3,
        "CaO" => (remaining * 0.18).round(2),
        "MgO" => (remaining * 0.14).round(2),
        "Na2O" => (remaining * 0.14).round(2),
        "K2O" => (remaining * 0.14).round(2),
        "TiO2" => (remaining * 0.05).round(2),
        "P2O5" => (remaining * 0.01).round(2),
        "MnO" => (remaining * 0.01).round(2),
        "LOI" => (remaining * 0.33).round(2)
      }
    end

    def standard_basalt_oxides
      {
        "SiO2" => 51.5, "Al2O3" => 14.0, "Fe2O3" => 13.0, "CaO" => 8.5,
        "MgO" => 4.8, "Na2O" => 2.8, "K2O" => 1.2, "TiO2" => 2.4,
        "P2O5" => 0.4, "MnO" => 0.2, "LOI" => 1.2
      }
    end
  end
end
