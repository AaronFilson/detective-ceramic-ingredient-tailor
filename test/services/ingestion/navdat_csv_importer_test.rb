# frozen_string_literal: true

require "test_helper"
require "rake"
require "stringio"
require "tempfile"

module Ingestion
  class NavdatCsvImporterTest < ActiveSupport::TestCase
    test "imports Western NA NAVDAT CSV with bare trace ppm columns, volcanic_rock sample_media, and idempotency" do
      csv = <<~CSV
        SAMPLE_ID,LATITUDE,LONGITUDE,ROCK_NAME,ROCK_TYPE,SIO2,AL2O3,FE2O3T,K2O,NA2O,CAO,MGO,TIO2,P2O5,MNO,LOI,RB,SR,BA,ZR,CR,NI,CU,ZN,PB,U,TH
        NAVDAT-CAS-01,44.0320,-121.7710,Rhyolite,volcanic,73.4,13.6,2.1,4.6,3.9,0.9,0.2,0.22,0.05,0.06,0.95,185,110,1250,240,12,8,14,55,24,5.4,16.2
        NAVDAT-CRB-02,45.7100,-121.5200,Basalt,volcanic,51.4,14.2,13.4,1.1,2.8,8.9,4.8,2.15,0.35,0.20,0.65,28,390,620,175,95,42,88,110,7.5,1.2,3.4
      CSV

      first = Ingestion::NavdatCsvImporter.new(StringIO.new(csv)).call
      assert_equal 2, first.imported
      assert_equal 2, first.created
      assert_equal 0, first.skipped

      rhyolite = ReferenceAssay.find_by!(source: "navdat", external_id: "NAVDAT-CAS-01")
      assert_equal "rhyolite", rhyolite.rock_type
      assert_equal "volcanic_rock", rhyolite.sample_media
      assert_in_delta 44.0320, rhyolite.latitude, 0.0001
      assert_in_delta(-121.7710, rhyolite.longitude, 0.0001)
      assert_in_delta 100.0, rhyolite.oxides.values.sum, 0.01

      # Bare trace element columns stay in ppm (NOT mistakenly treated as wt%!)
      assert_equal 185.0, rhyolite.trace_elements_ppm["Rb"]
      assert_equal 110.0, rhyolite.trace_elements_ppm["Sr"]
      assert_equal 1250.0, rhyolite.trace_elements_ppm["Ba"]
      assert_equal 240.0, rhyolite.trace_elements_ppm["Zr"]
      assert_equal 12.0, rhyolite.trace_elements_ppm["Cr"]
      assert_equal 8.0, rhyolite.trace_elements_ppm["Ni"]
      assert_equal 14.0, rhyolite.trace_elements_ppm["Cu"]
      assert_equal 55.0, rhyolite.trace_elements_ppm["Zn"]
      assert_equal 24.0, rhyolite.trace_elements_ppm["Pb"]
      assert_equal 5.4, rhyolite.trace_elements_ppm["U"]
      assert_equal 16.2, rhyolite.trace_elements_ppm["Th"]

      # Converted minor oxides >= 0.01 wt%
      assert_in_delta 0.1396, rhyolite.minor_oxides["BaO"], 0.001
      assert_in_delta 0.0324, rhyolite.minor_oxides["ZrO2"], 0.001
      assert_in_delta 0.0130, rhyolite.minor_oxides["SrO"], 0.001
      # Sub-threshold trace elements remain excluded from minor_oxides
      assert_nil rhyolite.minor_oxides["Cr2O3"]
      assert_nil rhyolite.minor_oxides["NiO"]
      assert_nil rhyolite.minor_oxides["CuO"]

      basalt = ReferenceAssay.find_by!(source: "navdat", external_id: "NAVDAT-CRB-02")
      assert_in_delta 0.0461, basalt.minor_oxides["SrO"], 0.001
      assert_in_delta 0.0692, basalt.minor_oxides["BaO"], 0.001
      assert_in_delta 0.0139, basalt.minor_oxides["Cr2O3"], 0.001
      assert_in_delta 0.0110, basalt.minor_oxides["CuO"], 0.001
      assert_in_delta 0.0137, basalt.minor_oxides["ZnO"], 0.001

      second = Ingestion::NavdatCsvImporter.new(StringIO.new(csv)).call
      assert_equal 2, second.imported
      assert_equal 0, second.created
      assert_equal 2, second.updated
      assert_equal 2, ReferenceAssay.by_source("navdat").count
    end

    test "imports tab-delimited NAVDAT TSV with FEOT conversion in bulk: true mode" do
      tsv = [
        "NAVDAT Western North America Export",
        "SAMPLE_ID\tLATITUDE\tLONGITUDE\tROCK_TYPE\tSIO2\tAL2O3\tFEOT\tCAO\tMGO\tNA2O\tK2O\tBA\tSR\tCR\tPB\tU\tTH",
        "NAVDAT-TSV-1\t46.2000\t-122.1900\tdacite\t65.2\t16.4\t4.5\t4.4\t1.9\t4.3\t2.1\t950\t480\t120\t15\t3.1\t8.5"
      ].join("\n")

      result = Ingestion::NavdatCsvImporter.new(StringIO.new(tsv), bulk: true).call
      assert_equal 1, result.imported
      assert_equal 1, result.created

      dacite = ReferenceAssay.find_by!(source: "navdat", external_id: "NAVDAT-TSV-1")
      assert_equal "dacite", dacite.rock_type
      assert_equal "volcanic_rock", dacite.sample_media
      assert_operator dacite.oxides["Fe2O3"], :>, 4.9
      assert_equal 950.0, dacite.trace_elements_ppm["Ba"]
      assert_equal 3.1, dacite.trace_elements_ppm["U"]
      assert_in_delta 0.1061, dacite.minor_oxides["BaO"], 0.001
      assert_in_delta 0.0175, dacite.minor_oxides["Cr2O3"], 0.001
    end

    test "geochem:import_navdat rake task imports NAVDAT export cleanly" do
      Rails.application.load_tasks if Rake::Task.tasks.empty?
      task = Rake::Task["geochem:import_navdat"]
      task.reenable

      Tempfile.create([ "navdat_rake", ".csv" ]) do |f|
        f.write("SAMPLE_ID,LATITUDE,LONGITUDE,ROCK_NAME,SIO2,AL2O3,FE2O3T,K2O,NA2O,CAO,MGO,RB,SR,BA\n")
        f.write("RAKE-NAV-1,44.10,-121.70,dacite,66.0,16.1,4.8,2.4,4.2,4.1,1.6,70,420,900\n")
        f.flush

        assert_output(/NAVDAT import complete: imported=1/) do
          task.invoke(f.path)
        end
      end

      assay = ReferenceAssay.find_by!(source: "navdat", external_id: "RAKE-NAV-1")
      assert_equal "volcanic_rock", assay.sample_media
      assert_equal 70.0, assay.trace_elements_ppm["Rb"]
    end
  end
end
