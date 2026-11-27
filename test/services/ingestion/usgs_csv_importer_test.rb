# frozen_string_literal: true

require "test_helper"
require "stringio"

class Ingestion::UsgsCsvImporterTest < ActiveSupport::TestCase
  test "imports direct oxide wt% rows, normalizes to 100%, and is idempotent" do
    csv = <<~CSV
      LAB_ID,LATITUDE,LONGITUDE,ROCK_TYPE,SIO2,AL2O3,FE2O3,CAO,MGO,NA2O,K2O,TIO2,P2O5,MNO,LOI
      USGS-T-1,47.2529,-122.4443,Glacial_Clay,58.0,17.0,6.0,3.0,2.5,2.5,2.0,0.8,0.2,0.1,5.9
    CSV

    first = Ingestion::UsgsCsvImporter.new(StringIO.new(csv)).call
    assert_equal 1, first.imported
    assert_equal 1, first.created
    assert_equal 0, first.updated
    assert_equal 0, first.skipped

    assay = ReferenceAssay.find_by!(source: "usgs_ngdb", external_id: "USGS-T-1")
    assert_equal "glacial_clay", assay.rock_type
    assert_in_delta 47.2529, assay.latitude, 0.0001
    assert_in_delta(-122.4443, assay.longitude, 0.0001)
    assert_equal CeramicOxides::KEYS.sort, assay.oxides.keys.sort
    assert_in_delta 100.0, assay.oxides.values.sum, 0.01
    # Original sum was 98.0 -> SiO2 scaled from 58.0 to 58.0 * 100 / 98.0 = 59.1837
    assert_in_delta 59.1837, assay.oxides["SiO2"], 0.01

    # Re-importing the same CSV must update in-place without duplicates
    second = Ingestion::UsgsCsvImporter.new(StringIO.new(csv)).call
    assert_equal 1, second.imported
    assert_equal 0, second.created
    assert_equal 1, second.updated
    assert_equal 1, ReferenceAssay.where(source: "usgs_ngdb", external_id: "USGS-T-1").count
  end

  test "converts elemental wt% and ppm columns to oxides via stoichiometric factors" do
    # Si_pct = 28.0 -> SiO2 = 59.9004; Al_pct = 9.0 -> Al2O3 = 17.0055
    # Fe_pct = 4.5 -> Fe2O3 = 6.43365; Ca_pct = 2.0 -> CaO = 2.7984
    # Mg_ppm = 15000 (1.5 wt%) -> MgO = 2.48745; Ti_ppm = 4800 (0.48 wt%) -> TiO2 = 0.80088
    # Mn_ppm = 800 (0.08 wt%) -> MnO = 0.103296; LOI = 6.0
    csv = <<~CSV
      LAB_ID,LAT,LNG,ROCK_TYPE,SI_PCT,AL_PCT,FE_PCT,CA_PCT,MG_PPM,TI_PPM,MN_PPM,LOI
      USGS-EL-1,47.30,-122.40,shale,28.0,9.0,4.5,2.0,15000,4800,800,6.0
    CSV

    result = Ingestion::UsgsCsvImporter.new(StringIO.new(csv)).call
    assert_equal 1, result.imported
    assert_equal 0, result.skipped

    assay = ReferenceAssay.find_by!(source: "usgs_ngdb", external_id: "USGS-EL-1")
    assert_in_delta 100.0, assay.oxides.values.sum, 0.01

    # Verify relative stoichiometry (SiO2 / Al2O3 ratio = 59.9004 / 17.0055 = 3.5224)
    ratio = assay.oxides["SiO2"] / assay.oxides["Al2O3"]
    assert_in_delta (28.0 * 2.1393) / (9.0 * 1.8895), ratio, 0.005
    assert assay.oxides["TiO2"] > 0.7
    assert assay.oxides["MnO"] > 0.09
    assert assay.oxides["MgO"] > 2.4
  end

  test "converts FeO to Fe2O3 and combines Fe2O3 plus FeO when both present" do
    csv = <<~CSV
      LAB_ID,LATITUDE,LONGITUDE,ROCK_TYPE,SIO2,AL2O3,FE2O3,FEO,CAO,LOI
      USGS-FE-1,46.94,-119.98,basalt,50.0,15.0,,9.0,10.0,1.0
      USGS-FE-2,46.95,-119.99,basalt,50.0,15.0,2.0,7.0,10.0,1.0
    CSV

    result = Ingestion::UsgsCsvImporter.new(StringIO.new(csv)).call
    assert_equal 2, result.imported

    a1 = ReferenceAssay.find_by!(source: "usgs_ngdb", external_id: "USGS-FE-1")
    # FeO = 9.0 -> Fe2O3 = 10.0017; total = 86.0017 -> normalized Fe2O3 ~ 11.6297%
    expected_fe1 = (9.0 * 1.1113) / (50.0 + 15.0 + 9.0 * 1.1113 + 10.0 + 1.0) * 100.0
    assert_in_delta expected_fe1, a1.oxides["Fe2O3"], 0.02

    a2 = ReferenceAssay.find_by!(source: "usgs_ngdb", external_id: "USGS-FE-2")
    # Fe2O3 = 2.0 + 7.0 * 1.1113 = 9.7791
    expected_fe2 = (2.0 + 7.0 * 1.1113) / (50.0 + 15.0 + 2.0 + 7.0 * 1.1113 + 10.0 + 1.0) * 100.0
    assert_in_delta expected_fe2, a2.oxides["Fe2O3"], 0.02
  end

  test "rejects rows missing valid SiO2, Al2O3, or coordinates" do
    csv = <<~CSV
      LAB_ID,LATITUDE,LONGITUDE,ROCK_TYPE,SIO2,AL2O3,FE2O3,LOI
      GOOD-1,47.25,-122.44,clay,60.0,18.0,5.0,7.0
      NO-SIO2,47.25,-122.44,clay,,18.0,5.0,7.0
      NO-AL2O3,47.25,-122.44,clay,60.0,<0.01,5.0,7.0
      SENTINEL,47.25,-122.44,clay,-9999,18.0,5.0,7.0
      NO-COORDS,,,clay,60.0,18.0,5.0,7.0
      BAD-LAT,95.0,-122.44,clay,60.0,18.0,5.0,7.0
    CSV

    result = Ingestion::UsgsCsvImporter.new(StringIO.new(csv)).call
    assert_equal 1, result.imported
    assert_equal 5, result.skipped
    assert_equal 5, result.errors.size
    assert ReferenceAssay.exists?(source: "usgs_ngdb", external_id: "GOOD-1")
    assert_not ReferenceAssay.exists?(source: "usgs_ngdb", external_id: "NO-SIO2")
  end

  test "imports 50-row seed CSV cleanly with Tacoma/Seattle baseline coverage" do
    seed_path = Rails.root.join("db/seeds/sample_assays.csv")
    result = Ingestion::UsgsCsvImporter.new(seed_path).call

    assert_equal 50, result.imported
    assert_equal 0, result.skipped

    assays = ReferenceAssay.by_source("usgs_ngdb")
    assert_equal 50, assays.count

    required_types = %w[
      glacial_clay alluvial_clay marine_clay shale basalt andesite
      granite granodiorite rhyolite gabbro limestone siltstone kaolin_clay
    ]
    present_types = assays.distinct.pluck(:rock_type)
    required_types.each do |rt|
      assert_includes present_types, rt, "Expected seed CSV to include rock_type=#{rt}"
    end

    assays.find_each do |assay|
      assert_in_delta 100.0, assay.oxides.values.sum, 0.01, "Oxides sum out of range for #{assay.external_id}"
    end

    nearby_tacoma = assays.within_radius(47.2529, -122.4443, 50_000).count
    assert_operator nearby_tacoma, :>=, 12, "Expected >= 12 assays within 50km of Tacoma, got #{nearby_tacoma}"

    # Verify idempotency on second run
    second = Ingestion::UsgsCsvImporter.new(seed_path).call
    assert_equal 50, second.imported
    assert_equal 0, second.created
    assert_equal 50, second.updated
    assert_equal 50, ReferenceAssay.by_source("usgs_ngdb").count
  end
end
