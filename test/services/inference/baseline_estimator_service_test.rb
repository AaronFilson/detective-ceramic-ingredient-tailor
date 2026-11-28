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
      sio2_values = [ 56.0, 58.0, 60.0, 62.0, 64.0 ]
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
      [ 47.48, 47.55, 47.05 ].each_with_index do |lat, idx|
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
      assert_equal [ kaolin_a.id, kaolin_b.id ].sort, result.matched_assay_ids.sort
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
      [ 10.0, 20.0, 30.0, 40.0 ].each_with_index do |sio2, idx|
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

    test "community_verified_xrf assays receive 2.5x weight and pull estimated oxides strongly toward verified chemistry" do
      # 4 standard assays at same spot with SiO2=56%, plus 2 community_verified_xrf assays at same spot with SiO2=68%
      4.times do |idx|
        create_assay!(
          source: "usgs_ngdb",
          external_id: "STD-CLAY-#{idx}",
          rock_type: "glacial_clay",
          lat: TACOMA_LAT,
          lng: TACOMA_LNG,
          oxides: standard_clay_oxides(sio2: 56.0 + (idx * 0.2), al2o3: 17.0, fe2o3: 6.0)
        )
      end

      2.times do |idx|
        create_assay!(
          source: "community_verified_xrf",
          external_id: "VERIFIED-CLAY-#{idx}",
          rock_type: "glacial_clay",
          lat: TACOMA_LAT,
          lng: TACOMA_LNG,
          oxides: standard_clay_oxides(sio2: 68.0 + (idx * 0.2), al2o3: 17.0, fe2o3: 6.0)
        )
      end

      sample = UserSample.create!(
        title: "Verified Neighborhood Clay",
        material_category: :wild_clay,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG
      )

      result = Inference::BaselineEstimatorService.call(sample)

      assert_equal :local_15km, result.strategy
      # Unweighted median of [56.0, 56.2, 56.4, 56.6, 68.0, 68.2] is 56.5
      assert_in_delta 56.5, result.oxide_ranges["SiO2"]["median"], 0.05
      # With 2.5x verified weight (total weight 4*1 + 2*2.5 = 9.0), weighted SiO2 shifts well above 61%
      assert_operator result.oxide_ranges["SiO2"]["weighted_median"], :>, 61.0
      assert_operator result.oxides["SiO2"], :>, 61.0
      assert_in_delta 100.0, result.oxides.values.sum, 0.01
      assert result.reasoning_log.any? { |entry| entry.include?("verified-lab boost") }
    end

    test "inverse-distance weighting makes a nearby assay outweigh four distant 40km assays" do
      # 1 assay right at sample pin (0 km) with high SiO2 = 68%
      create_assay!(
        external_id: "CLOSE-CLAY-0",
        rock_type: "glacial_clay",
        lat: TACOMA_LAT,
        lng: TACOMA_LNG,
        oxides: standard_clay_oxides(sio2: 68.0, al2o3: 17.0, fe2o3: 5.0)
      )

      # 4 assays ~40 km away (0.36 deg north) with low SiO2 = 54..55.5%
      4.times do |idx|
        create_assay!(
          external_id: "FAR-CLAY-#{idx}",
          rock_type: "glacial_clay",
          lat: TACOMA_LAT + 0.36 + (idx * 0.002),
          lng: TACOMA_LNG,
          oxides: standard_clay_oxides(sio2: 54.0 + (idx * 0.5), al2o3: 17.0, fe2o3: 5.0)
        )
      end

      sample = UserSample.create!(
        title: "Regional IDW Test Clay",
        material_category: :wild_clay,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG
      )

      result = Inference::BaselineEstimatorService.call(sample)

      assert_equal :regional_50km, result.strategy
      # Empirical unweighted median of [54.0, 54.5, 55.0, 55.5, 68.0] is 55.0
      assert_in_delta 55.0, result.oxide_ranges["SiO2"]["median"], 0.05
      # IDW pulls estimated SiO2 strongly toward the 0 km assay (68%)
      assert_operator result.oxides["SiO2"], :>, 63.0
      assert_in_delta 100.0, result.oxides.values.sum, 0.01
      assert result.reasoning_log.any? { |entry| entry.include?("IDW spatial distance") }
    end

    test "USDA SSURGO soil profile prior nudges CaO/LOI for calcareous soil and Al2O3/LOI for clay-rich B horizon on wild_clay" do
      5.times do |idx|
        create_assay!(
          external_id: "SOIL-BASE-#{idx}",
          rock_type: "glacial_clay",
          lat: TACOMA_LAT,
          lng: TACOMA_LNG,
          oxides: standard_clay_oxides(sio2: 59.0, al2o3: 17.0, fe2o3: 6.0)
        )
      end

      base_sample = UserSample.create!(
        title: "Clay Without Soil Profile",
        material_category: :wild_clay,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG
      )
      base_result = Inference::BaselineEstimatorService.call(base_sample)

      soil_profile = SoilProfile.create!(
        mukey: "900101",
        map_unit_name: "Kitsap silt loam",
        component_name: "Kitsap",
        component_percent: 85,
        horizons: [
          { "hzname" => "A", "top_cm" => 0, "bottom_cm" => 25, "clay_pct" => 22.0, "plasticity_index" => 10.0, "caco3_pct" => 0.0 },
          { "hzname" => "Bt", "top_cm" => 25, "bottom_cm" => 85, "clay_pct" => 44.0, "plasticity_index" => 25.0, "caco3_pct" => 8.0 }
        ],
        max_clay_pct: 44.0,
        max_plasticity_index: 25.0,
        max_caco3_pct: 8.0,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG,
        fetched_at: Time.current
      )

      soil_sample = UserSample.create!(
        title: "Clay With Calcareous Claypan Profile",
        material_category: :wild_clay,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG,
        soil_profile: soil_profile
      )
      soil_result = Inference::BaselineEstimatorService.call(soil_sample)

      assert_operator soil_result.oxides["CaO"], :>, base_result.oxides["CaO"] + 1.5
      assert_operator soil_result.oxides["Al2O3"], :>, base_result.oxides["Al2O3"] + 0.3
      assert_operator soil_result.oxides["LOI"], :>, base_result.oxides["LOI"] + 1.5
      assert_in_delta 100.0, soil_result.oxides.values.sum, 0.01

      assert soil_result.reasoning_log.any? { |line| line.include?("USDA SSURGO soil horizon prior") && line.include?("8.0% CaCO3") }
      assert soil_result.reasoning_log.any? { |line| line.include?("USDA SSURGO soil horizon prior") && line.include?("44.0% clay") && line.include?("Plasticity Index 25.0") }

      # Non-wild_clay samples (e.g. crushed_rock) must NOT receive topsoil/subsoil soil priors
      rock_sample = UserSample.create!(
        title: "Crushed Rock Over Calcareous Soil",
        material_category: :crushed_rock,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG,
        soil_profile: soil_profile
      )
      rock_result = Inference::BaselineEstimatorService.call(rock_sample)
      assert_not rock_result.reasoning_log.any? { |line| line.include?("USDA SSURGO soil horizon prior") }
    end

    test "returns empty minor_oxides and trace_elements_ppm for category defaults and assays without trace data" do
      ocean_sample = UserSample.create!(
        title: "Ocean Default Clay",
        material_category: :wild_clay,
        latitude: 0.0,
        longitude: 0.0
      )
      default_result = Inference::BaselineEstimatorService.call(ocean_sample)
      assert_equal({}, default_result.minor_oxides)
      assert_equal({}, default_result.trace_elements_ppm)
      assert_not default_result.reasoning_log.any? { |line| line.include?("Propagated") }

      5.times do |idx|
        create_assay!(
          external_id: "NO-TRACE-#{idx}",
          rock_type: "glacial_clay",
          lat: TACOMA_LAT + (idx * 0.004),
          lng: TACOMA_LNG,
          oxides: standard_clay_oxides(sio2: 59.0)
        )
      end

      local_sample = UserSample.create!(
        title: "No Trace Clay",
        material_category: :wild_clay,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG
      )
      local_result = Inference::BaselineEstimatorService.call(local_sample)
      assert_equal({}, local_result.minor_oxides)
      assert_equal({}, local_result.trace_elements_ppm)
      assert_not local_result.reasoning_log.any? { |line| line.include?("Propagated") }
    end

    test "propagates weighted-median minor oxides (>= 0.01 wt%) and conservative P75 trace elements with reasoning log" do
      # 5 equal-distance assays: 3 report BaO/SrO and 5 report As/Rb/S
      as_values = [ 10.0, 20.0, 40.0, 60.0, 100.0 ] # P75 = 60.0
      bao_values = [ 1.8, 2.4, 3.0, nil, nil ]      # 3/5 = 60% >= 20%, median = 2.4
      sro_values = [ 0.12, 0.18, 0.24, nil, nil ]   # median = 0.18
      tiny_values = [ 0.004, 0.006, 0.008, nil, nil ] # < 0.01 wt% -> excluded

      5.times do |idx|
        minors = {}
        minors["BaO"] = bao_values[idx] if bao_values[idx]
        minors["SrO"] = sro_values[idx] if sro_values[idx]
        minors["CuO"] = tiny_values[idx] if tiny_values[idx]

        create_assay!(
          source: "usgs_ds801",
          external_id: "TRACE-DS801-#{idx}",
          rock_type: "glacial_clay",
          lat: TACOMA_LAT,
          lng: TACOMA_LNG,
          oxides: standard_clay_oxides(sio2: 59.0),
          minor_oxides: minors,
          trace_elements_ppm: {
            "As" => as_values[idx],
            "Rb" => 100.0 + (idx * 50.0), # [100, 150, 200, 250, 300] -> P75 = 250.0
            "S" => 1000.0 + (idx * 500.0) # [1000, 1500, 2000, 2500, 3000] -> P75 = 2500.0
          }
        )
      end

      sample = UserSample.create!(
        title: "Tacoma Trace Clay",
        material_category: :wild_clay,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG
      )

      result = Inference::BaselineEstimatorService.call(sample)

      assert_equal :local_15km, result.strategy
      assert_in_delta 2.4, result.minor_oxides["BaO"], 0.0001
      assert_in_delta 0.18, result.minor_oxides["SrO"], 0.0001
      assert_nil result.minor_oxides["CuO"]

      assert_in_delta 60.0, result.trace_elements_ppm["As"], 0.1
      assert_in_delta 250.0, result.trace_elements_ppm["Rb"], 0.1
      assert_in_delta 2500.0, result.trace_elements_ppm["S"], 0.1

      assert result.reasoning_log.any? { |line|
        line.include?("Propagated regional minor oxides") &&
          line.include?("BaO") &&
          line.include?("SrO") &&
          line.include?("P75 trace elements") &&
          line.include?("As") &&
          line.include?("5/5 matched assays")
      }
    end

    test "scales sparse (< 20%) unverified minor oxides conservatively while keeping authoritative DS-801/verified minor oxides unscaled" do
      # 10 equal-distance glacial_clay assays:
      # - 1 unverified usgs_ngdb assay reports ZnO = 0.40 (10% coverage < 20% -> scaled by 0.5 to 0.20)
      # - 1 authoritative usgs_ds801 assay reports Li2O = 1.25 (10% coverage but DS-801 -> full 1.25 retained)
      8.times do |idx|
        create_assay!(
          source: "usgs_ngdb",
          external_id: "SPARSE-PLAIN-#{idx}",
          rock_type: "glacial_clay",
          lat: TACOMA_LAT,
          lng: TACOMA_LNG,
          oxides: standard_clay_oxides(sio2: 59.0)
        )
      end

      create_assay!(
        source: "usgs_ngdb",
        external_id: "SPARSE-ZNO",
        rock_type: "glacial_clay",
        lat: TACOMA_LAT,
        lng: TACOMA_LNG,
        oxides: standard_clay_oxides(sio2: 59.0),
        minor_oxides: { "ZnO" => 0.40 }
      )

      create_assay!(
        source: "usgs_ds801",
        external_id: "SPARSE-DS801-LI",
        rock_type: "glacial_clay",
        lat: TACOMA_LAT,
        lng: TACOMA_LNG,
        oxides: standard_clay_oxides(sio2: 59.0),
        minor_oxides: { "Li2O" => 1.25 }
      )

      sample = UserSample.create!(
        title: "Sparse Minor Scaling Clay",
        material_category: :wild_clay,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG
      )

      result = Inference::BaselineEstimatorService.call(sample)

      assert_equal 10, result.sample_count
      assert_in_delta 0.20, result.minor_oxides["ZnO"], 0.0001
      assert_in_delta 1.25, result.minor_oxides["Li2O"], 0.0001
    end

    test "spatial minor/trace propagation triggers HazardScreenerService alerts for As, BaO, S, and LCT K/Rb" do
      # Create 5 nearby GEOROC/DS-801 pegmatite assays carrying elevated K2O, Rb (K/Rb < 160), As, BaO, and S
      5.times do |idx|
        create_assay!(
          source: idx.even? ? "georoc" : "usgs_ds801",
          external_id: "PEG-HAZ-#{idx}",
          rock_type: "pegmatite",
          lat: TACOMA_LAT + (idx * 0.002),
          lng: TACOMA_LNG,
          oxides: {
            "SiO2" => 68.0, "Al2O3" => 17.0, "Fe2O3" => 0.8, "CaO" => 0.8,
            "MgO" => 0.3, "Na2O" => 4.0, "K2O" => 7.0, "TiO2" => 0.1,
            "P2O5" => 0.3, "MnO" => 0.1, "LOI" => 1.6
          },
          minor_oxides: { "BaO" => 2.6, "Li2O" => 1.8 },
          trace_elements_ppm: { "As" => 75.0, "Rb" => 520.0, "S" => 2400.0 }
        )
      end

      unit = GeologicUnit.create!(
        macrostrat_id: 51099,
        name: "Cascade Pegmatite Belt",
        lithology: { "raw" => "pegmatite" }
      )
      sample = UserSample.create!(
        title: "Wild Pegmatite Outcrop",
        material_category: :crushed_rock,
        latitude: TACOMA_LAT,
        longitude: TACOMA_LNG,
        geologic_unit: unit
      )

      assay = Inference::SampleEstimatorService.call(sample)
      assert_in_delta 2.6, assay.minor_oxides["BaO"], 0.01
      assert_in_delta 1.8, assay.minor_oxides["Li2O"], 0.01
      assert_in_delta 75.0, assay.trace_elements_ppm["As"], 0.5
      assert_in_delta 520.0, assay.trace_elements_ppm["Rb"], 1.0
      assert_operator assay.umf_formula.dig("fluxes", "Li2O").to_f, :>, 0.1

      screening = Chemistry::HazardScreenerService.call(
        assay_result: assay,
        user_sample: sample,
        nearby_minerals: [],
        nearby_xrd: {}
      )
      codes = screening.alerts.map { |a| a[:code] }
      assert_includes codes, "toxic_arsenic"
      assert_includes codes, "barium_toxicity"
      assert_includes codes, "sulfide_degassing"
      assert_includes codes, "lct_pegmatite_pathfinder"
      assert_operator screening.k_rb_ratio, :<, 160.0
      assert screening.food_safe_caution?
    end

    private

    def create_assay!(external_id:, rock_type:, lat:, lng:, oxides:, source: "test_seed", minor_oxides: {}, trace_elements_ppm: {})
      ReferenceAssay.create!(
        source: source,
        external_id: external_id,
        rock_type: rock_type,
        latitude: lat,
        longitude: lng,
        oxides: oxides,
        minor_oxides: minor_oxides,
        trace_elements_ppm: trace_elements_ppm
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
