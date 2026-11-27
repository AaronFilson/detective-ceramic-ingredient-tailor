# frozen_string_literal: true

require "test_helper"
require "stringio"

module Ingestion
  class UsgsDs801ImporterTest < ActiveSupport::TestCase
    setup do
      ReferenceAssay.where(source: "usgs_ds801").delete_all
    end

    test "imports DS-801 elemental wt%, trace ppm, minor oxides, and Rietveld XRD mineralogy with exact stoichiometry" do
      csv = <<~CSV
        SiteID,Latitude,Longitude,Horizon,Locality,Parent_Material,Si_Pct,Al_Pct,Fe_Pct,Ca_Pct,Mg_Pct,Na_Pct,K_Pct,Ti_Pct,P_Pct,S_Pct,Mn_ppm,As_ppm,Ba_ppm,Cd_ppm,Ce_ppm,Co_ppm,Cr_ppm,Cs_ppm,Cu_ppm,Li_ppm,Nb_ppm,Ni_ppm,Pb_ppm,Rb_ppm,Sn_ppm,Sr_ppm,Th_ppm,U_ppm,V_ppm,Zn_ppm,Zr_ppm,Quartz,Total_K_feldspar,Total_Plagioclase,Total_Clays,Kaolinite,Illite,Smectite,Chlorite,Calcite,Dolomite,Hornblende,Hematite,Gypsum,Pyrite
        DS801-TEST-1,47.2580,-122.4520,C,Tacoma WA,Vashon Glacial Till,28.0,8.5,4.2,2.0,1.4,1.9,1.6,0.48,0.08,0.05,760,7.5,640,0.2,48,16,80,3.2,35,30,11,45,19,65,2.1,340,7.2,2.2,120,88,190,32.0,8.0,23.0,32.0,6.0,12.0,9.0,5.0,1.0,0.0,4.0,0.0,0.0,0.0
      CSV

      result = Ingestion::UsgsDs801Importer.new(StringIO.new(csv)).call

      assert_equal 1, result.imported
      assert_equal 1, result.created
      assert_equal 0, result.updated
      assert_equal 0, result.skipped
      assert_empty result.errors

      assay = ReferenceAssay.find_by!(source: "usgs_ds801", external_id: "DS801-TEST-1-C")
      assert_equal "soil_c_horizon", assay.sample_media
      assert_equal "glacial_clay", assay.rock_type
      assert_in_delta 47.2580, assay.latitude, 0.0001
      assert_in_delta(-122.4520, assay.longitude, 0.0001)

      # Major oxides normalized to 100.0% with exact SiO2/Al2O3 stoichiometry
      assert_equal CeramicOxides::KEYS.sort, assay.oxides.keys.sort
      assert_in_delta 100.0, assay.oxides.values.sum, 0.01
      expected_ratio = (28.0 * 2.1393) / (8.5 * 1.8895)
      assert_in_delta expected_ratio, assay.oxides["SiO2"] / assay.oxides["Al2O3"], 0.005
      assert_operator assay.oxides["MnO"], :>, 0.08
      assert_operator assay.oxides["LOI"], :>, 2.0

      # Trace elements preserved in ppm (including S converted from S_Pct 0.05% => 500 ppm)
      assert_in_delta 7.5, assay.trace_elements_ppm["As"], 0.01
      assert_in_delta 640.0, assay.trace_elements_ppm["Ba"], 0.01
      assert_in_delta 340.0, assay.trace_elements_ppm["Sr"], 0.01
      assert_in_delta 190.0, assay.trace_elements_ppm["Zr"], 0.01
      assert_in_delta 65.0, assay.trace_elements_ppm["Rb"], 0.01
      assert_in_delta 30.0, assay.trace_elements_ppm["Li"], 0.01
      assert_in_delta 19.0, assay.trace_elements_ppm["Pb"], 0.01
      assert_in_delta 80.0, assay.trace_elements_ppm["Cr"], 0.01
      assert_in_delta 500.0, assay.trace_elements_ppm["S"], 0.01

      # Minor oxides stoichiometrically derived from trace elements + S_Pct
      assert_in_delta(0.064 * 1.1165, assay.minor_oxides["BaO"], 0.0005)
      assert_in_delta(0.034 * 1.1826, assay.minor_oxides["SrO"], 0.0005)
      assert_in_delta(0.019 * 1.3508, assay.minor_oxides["ZrO2"], 0.0005)
      assert_in_delta(0.008 * 1.4615, assay.minor_oxides["Cr2O3"], 0.0005)
      assert_in_delta(0.05 * 2.4972, assay.minor_oxides["SO3"], 0.0005)
      assert_in_delta(0.003 * 2.1527, assay.minor_oxides["Li2O"], 0.0005)

      # Quantitative Rietveld XRD mineralogy captured cleanly
      assert_in_delta 32.0, assay.xrd_mineralogy["quartz"], 0.01
      assert_in_delta 8.0, assay.xrd_mineralogy["k_feldspar"], 0.01
      assert_in_delta 23.0, assay.xrd_mineralogy["plagioclase"], 0.01
      assert_in_delta 6.0, assay.xrd_mineralogy["kaolinite"], 0.01
      assert_in_delta 12.0, assay.xrd_mineralogy["illite"], 0.01
      assert_in_delta 9.0, assay.xrd_mineralogy["smectite"], 0.01
      assert_in_delta 5.0, assay.xrd_mineralogy["chlorite"], 0.01
      assert_in_delta 1.0, assay.xrd_mineralogy["calcite"], 0.01
      assert_in_delta 4.0, assay.xrd_mineralogy["hornblende"], 0.01
      assert_nil assay.xrd_mineralogy["gypsum"]
    end

    test "estimates SiO2 cleanly from XRD stoichiometry and mass balance when Si is omitted in genuine DS-801 rows" do
      # Real USGS DS-801 4-acid ICP tables omit Si; Georgia kaolin C-horizon row with Al_Pct + XRD
      csv = <<~CSV
        SiteID,Latitude,Longitude,Horizon,Al_Pct,Fe_Pct,Ca_Pct,Mg_Pct,Na_Pct,K_Pct,Ti_Pct,P_Pct,Mn_ppm,Quartz,Total_K_feldspar,Total_Clays,Kaolinite,Illite,Hematite
        DS801-KAOLIN-1,32.9815,-82.8101,C,15.60,1.35,0.12,0.16,0.09,0.52,0.94,0.03,110,23.0,2.0,73.0,67.0,6.0,2.0
      CSV

      result = Ingestion::UsgsDs801Importer.new(StringIO.new(csv)).call

      assert_equal 1, result.imported
      assert_equal 0, result.skipped

      assay = ReferenceAssay.find_by!(source: "usgs_ds801", external_id: "DS801-KAOLIN-1-C")
      assert_equal "kaolin_clay", assay.rock_type
      assert_equal "soil_c_horizon", assay.sample_media
      assert_equal true, assay.raw_metadata["sio2_estimated"]
      assert_in_delta 100.0, assay.oxides.values.sum, 0.01
      # Realistic kaolin soil chemistry: ~54-60% SiO2, ~28-31% Al2O3, ~9-11% LOI
      assert_operator assay.oxides["SiO2"], :>=, 52.0
      assert_operator assay.oxides["SiO2"], :<=, 62.0
      assert_operator assay.oxides["Al2O3"], :>=, 26.0
      assert_operator assay.oxides["LOI"], :>=, 8.0
    end

    test "parses TSV format and distinguishes Top5, A, and C horizons sharing the same SiteID" do
      tsv = [
        "SiteID\tLatitude\tLongitude\tHorizon\tAl_Pct\tFe_Pct\tCa_Pct\tK_Pct\tQuartz\tKaolinite\tIllite\tCalcite\tDolomite",
        "1042\t44.9429\t-123.0351\tTop5\t8.2\t4.1\t1.5\t1.6\t42\t8\t12\t0\t0",
        "1042\t44.9429\t-123.0351\tA\t8.8\t4.4\t1.4\t1.7\t38\t10\t14\t0\t0",
        "1042\t44.9429\t-123.0351\tC\t6.5\t2.5\t8.0\t1.5\t35\t4\t8\t14\t5"
      ].join("\n")

      result = Ingestion::UsgsDs801Importer.new(StringIO.new(tsv)).call

      assert_equal 3, result.imported
      assert_equal 3, result.created
      assert_equal 0, result.skipped

      top5 = ReferenceAssay.find_by!(source: "usgs_ds801", external_id: "1042-TOP5")
      a_hz = ReferenceAssay.find_by!(source: "usgs_ds801", external_id: "1042-A")
      c_hz = ReferenceAssay.find_by!(source: "usgs_ds801", external_id: "1042-C")

      assert_equal "soil_top5_horizon", top5.sample_media
      assert_equal "soil_a_horizon", a_hz.sample_media
      assert_equal "soil_c_horizon", c_hz.sample_media
      assert_equal "marl", c_hz.rock_type
    end

    test "rejects rows missing coordinates, missing both Al and Si, or missing Si without silicate XRD" do
      csv = <<~CSV
        SiteID,Latitude,Longitude,Horizon,Si_Pct,Al_Pct,Fe_Pct,Quartz,Total_Clays
        GOOD-1,47.25,-122.44,C,,8.5,4.2,35.0,28.0
        NO-COORDS,,,C,28.0,8.5,4.2,35.0,28.0
        BAD-LAT,95.0,-122.44,C,28.0,8.5,4.2,35.0,28.0
        NO-SI-OR-AL,47.25,-122.44,C,<0.01,-9999,4.2,35.0,28.0
        NO-SI-NO-XRD,47.25,-122.44,C,,8.5,4.2,,
      CSV

      result = Ingestion::UsgsDs801Importer.new(StringIO.new(csv)).call

      assert_equal 1, result.imported
      assert_equal 4, result.skipped
      assert_equal 4, result.errors.size
      assert ReferenceAssay.exists?(source: "usgs_ds801", external_id: "GOOD-1-C")
      assert_not ReferenceAssay.exists?(source: "usgs_ds801", external_id: "NO-SI-OR-AL-C")
      assert_not ReferenceAssay.exists?(source: "usgs_ds801", external_id: "NO-SI-NO-XRD-C")
    end

    test "imports 12-row seed CSV db/seeds/sample_ds801_soils.csv cleanly and idempotently in both individual and bulk modes" do
      seed_path = Rails.root.join("db/seeds/sample_ds801_soils.csv")
      assert File.exist?(seed_path), "Expected #{seed_path} to exist"

      first = Ingestion::UsgsDs801Importer.new(seed_path).call
      assert_equal 12, first.imported
      assert_equal 12, first.created
      assert_equal 0, first.updated
      assert_equal 0, first.skipped
      assert_empty first.errors

      assays = ReferenceAssay.by_source("usgs_ds801")
      assert_equal 12, assays.count

      assays.find_each do |assay|
        assert_equal "soil_c_horizon", assay.sample_media
        assert_in_delta 100.0, assay.oxides.values.sum, 0.01, "Oxides did not sum to 100% for #{assay.external_id}"
        assert_predicate assay.minor_oxides, :present?, "Expected minor_oxides for #{assay.external_id}"
        assert_predicate assay.trace_elements_ppm, :present?, "Expected trace_elements_ppm for #{assay.external_id}"
        assert_predicate assay.xrd_mineralogy, :present?, "Expected xrd_mineralogy for #{assay.external_id}"
        %w[Rb Ba Sr As Pb Cr Zr Li S].each do |el|
          assert assay.trace_elements_ppm.key?(el), "Expected trace element #{el} on #{assay.external_id}"
        end
      end

      # Verify regional ceramic coverage (Puget Sound / Tacoma, Spokane, Willamette, Georgia Kaolin, Iowa Till)
      assert_operator assays.within_radius(47.2529, -122.4443, 50_000).count, :>=, 3
      assert_equal "kaolin_clay", ReferenceAssay.find_by!(source: "usgs_ds801", external_id: "DS801-GA-008-C").rock_type
      assert_equal "kaolin_clay", ReferenceAssay.find_by!(source: "usgs_ds801", external_id: "DS801-WA-004-C").rock_type
      assert_equal "glacial_clay", ReferenceAssay.find_by!(source: "usgs_ds801", external_id: "DS801-IA-009-C").rock_type
      assert_equal "alluvial_clay", ReferenceAssay.find_by!(source: "usgs_ds801", external_id: "DS801-OR-006-C").rock_type

      # Second run (individual) must be 100% idempotent
      second = Ingestion::UsgsDs801Importer.new(seed_path).call
      assert_equal 12, second.imported
      assert_equal 0, second.created
      assert_equal 12, second.updated
      assert_equal 12, ReferenceAssay.by_source("usgs_ds801").count

      # Bulk upsert mode must also preserve all JSONB fields idempotently
      bulk_run = Ingestion::UsgsDs801Importer.new(seed_path, bulk: true).call
      assert_equal 12, bulk_run.imported
      assert_equal 0, bulk_run.created
      assert_equal 12, bulk_run.updated
      assert_equal 12, ReferenceAssay.by_source("usgs_ds801").count

      tacoma_soil = ReferenceAssay.find_by!(source: "usgs_ds801", external_id: "DS801-WA-001-C")
      assert_equal "soil_c_horizon", tacoma_soil.sample_media
      assert_in_delta 31.0, tacoma_soil.xrd_mineralogy["quartz"], 0.01
      assert_predicate tacoma_soil.minor_oxides["BaO"], :positive?
    end
  end
end
