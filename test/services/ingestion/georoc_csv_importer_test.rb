# frozen_string_literal: true

require "test_helper"
require "rake"
require "stringio"
require "tempfile"

module Ingestion
  class GeorocCsvImporterTest < ActiveSupport::TestCase
    test "imports GEOROC CSV with (WT%)/(PPM) headers, strips References footer, and extracts minor_oxides and trace_elements_ppm" do
      csv = <<~CSV
        GEOROC Export - Cascade Arc Igneous Rocks
        CITATIONS,SAMPLE NAME,ROCK NAME,LATITUDE (MIN.),LONGITUDE (MIN.),SIO2(WT%),AL2O3(WT%),FEOT(WT%),CAO(WT%),MGO(WT%),NA2O(WT%),K2O(WT%),TIO2(WT%),P2O5(WT%),MNO(WT%),H2O+(WT%),CO2(WT%),LI(PPM),B(PPM),CR(PPM),CO(PPM),NI(PPM),CU(PPM),ZN(PPM),AS(PPM),RB(PPM),SR(PPM),ZR(PPM),BA(PPM),PB(PPM),U(PPM),TH(PPM),S(PPM),F(PPM)
        [1],GEO-RAINIER-01,ANDESITE,46.8523,-121.7603,60.4,17.2,5.8,6.1,3.2,3.8,1.7,0.85,0.22,0.11,0.55,0.15,520,350,240,18,45,60,85,12,58,520,165,890,14,2.8,7.4,2400,1800
        [2],GEO-PEG-02,PEGMATITE,48.1200,-118.2100,72.5,15.8,0.8,0.6,0.2,3.4,5.2,0.08,0.12,0.05,0.75,0.10,6200,1200,15,4,8,12,40,65,980,95,45,140,38,62,25,180,4500
        References:
        [1] Smith, J. (2024) Cascade Arc Geochemistry, Journal of Petrology.
        [2] Doe, A. (2023) Washington LCT Pegmatites, American Mineralogist.
      CSV

      result = Ingestion::GeorocCsvImporter.new(StringIO.new(csv)).call
      assert_equal 2, result.imported
      assert_equal 2, result.created
      assert_equal 0, result.skipped
      assert_empty result.errors

      andesite = ReferenceAssay.find_by!(source: "georoc", external_id: "GEO-RAINIER-01")
      assert_equal "andesite", andesite.rock_type
      assert_equal "igneous_rock", andesite.sample_media
      assert_in_delta 46.8523, andesite.latitude, 0.0001
      assert_in_delta(-121.7603, andesite.longitude, 0.0001)
      assert_in_delta 100.0, andesite.oxides.values.sum, 0.01
      # FEOT 5.8 * 1.1113 = 6.4455 before normalization
      assert_operator andesite.oxides["Fe2O3"], :>, 6.0
      # H2O+(0.55) + CO2(0.15) = 0.70 volatile fallback to LOI
      assert_in_delta 0.70, andesite.oxides["LOI"], 0.05

      # Trace elements captured in ppm
      assert_equal 520.0, andesite.trace_elements_ppm["Li"]
      assert_equal 350.0, andesite.trace_elements_ppm["B"]
      assert_equal 240.0, andesite.trace_elements_ppm["Cr"]
      assert_equal 58.0, andesite.trace_elements_ppm["Rb"]
      assert_equal 520.0, andesite.trace_elements_ppm["Sr"]
      assert_equal 165.0, andesite.trace_elements_ppm["Zr"]
      assert_equal 890.0, andesite.trace_elements_ppm["Ba"]
      assert_equal 12.0, andesite.trace_elements_ppm["As"]
      assert_equal 14.0, andesite.trace_elements_ppm["Pb"]
      assert_equal 2.8, andesite.trace_elements_ppm["U"]
      assert_equal 7.4, andesite.trace_elements_ppm["Th"]
      assert_equal 2400.0, andesite.trace_elements_ppm["S"]
      assert_equal 1800.0, andesite.trace_elements_ppm["F"]

      # Minor oxides converted via CeramicOxides::MINOR_ELEMENT_TO_OXIDE_FACTORS when >= 0.01 wt%
      assert_in_delta 0.1119, andesite.minor_oxides["Li2O"], 0.001
      assert_in_delta 0.1127, andesite.minor_oxides["B2O3"], 0.001
      assert_in_delta 0.0351, andesite.minor_oxides["Cr2O3"], 0.001
      assert_in_delta 0.0615, andesite.minor_oxides["SrO"], 0.001
      assert_in_delta 0.0223, andesite.minor_oxides["ZrO2"], 0.001
      assert_in_delta 0.0994, andesite.minor_oxides["BaO"], 0.001
      assert_in_delta 0.5993, andesite.minor_oxides["SO3"], 0.001
      assert_in_delta 0.18, andesite.minor_oxides["F"], 0.001
      # Sub-threshold trace elements (< 0.01% oxide) remain in trace_elements_ppm but NOT minor_oxides
      assert_nil andesite.minor_oxides["CoO"]
      assert_nil andesite.minor_oxides["NiO"]
      assert_nil andesite.minor_oxides["CuO"]

      pegmatite = ReferenceAssay.find_by!(source: "georoc", external_id: "GEO-PEG-02")
      assert_in_delta 1.3347, pegmatite.minor_oxides["Li2O"], 0.001
      assert_in_delta 0.3864, pegmatite.minor_oxides["B2O3"], 0.001
      assert_in_delta 0.45, pegmatite.minor_oxides["F"], 0.001
      assert_equal 980.0, pegmatite.trace_elements_ppm["Rb"]
      assert_equal 62.0, pegmatite.trace_elements_ppm["U"]
      assert_equal 65.0, pegmatite.trace_elements_ppm["As"]
    end

    test "strips Download from GEOROC footer blocks cleanly" do
      csv = <<~CSV
        SAMPLE NAME,ROCK NAME,LATITUDE (MIN.),LONGITUDE (MIN.),SIO2(WT%),AL2O3(WT%),FE2O3(WT%),LOI(WT%)
        GEO-FOOTER-1,BASALT,45.70,-121.52,51.2,14.1,12.5,1.2
        Download from GEOROC database on 2026-11-27
        Criteria: Cascade Volcanic Arc
      CSV

      result = Ingestion::GeorocCsvImporter.new(StringIO.new(csv)).call
      assert_equal 1, result.imported
      assert_equal 0, result.skipped
      assert ReferenceAssay.exists?(source: "georoc", external_id: "GEO-FOOTER-1")
    end

    test "BaseCsvImporter extracts direct minor oxide wt% columns, sample_media column, and persists in bulk: true mode" do
      csv = <<~CSV
        SAMPLE NAME,ROCK NAME,SAMPLE_MEDIA,LATITUDE (MIN.),LONGITUDE (MIN.),SIO2(WT%),AL2O3(WT%),FE2O3(WT%),LI2O(WT%),B2O3(WT%),CR2O3(WT%),F,ZRO2,S(WT%),RB(PPM),CS(PPM)
        GEO-DIRECT-1,LEPIDOLITE_PEGMATITE,pegmatite_rock,48.35,-118.05,68.0,18.5,0.6,2.15,0.45,0.08,0.65,0.12,0.25,1450,180
        GEO-DIRECT-2,CHROMITE_DUNITE,,48.72,-121.98,42.5,2.4,9.8,,,1.45,,0.04,,12,2
      CSV

      first = Ingestion::GeorocCsvImporter.new(StringIO.new(csv), bulk: true).call
      assert_equal 2, first.imported
      assert_equal 2, first.created
      assert_equal 0, first.skipped

      peg = ReferenceAssay.find_by!(source: "georoc", external_id: "GEO-DIRECT-1")
      assert_equal "pegmatite_rock", peg.sample_media
      assert_in_delta 2.15, peg.minor_oxides["Li2O"], 0.001
      assert_in_delta 0.45, peg.minor_oxides["B2O3"], 0.001
      assert_in_delta 0.08, peg.minor_oxides["Cr2O3"], 0.001
      assert_in_delta 0.65, peg.minor_oxides["F"], 0.001
      assert_in_delta 0.12, peg.minor_oxides["ZrO2"], 0.001
      assert_in_delta 0.6243, peg.minor_oxides["SO3"], 0.001
      assert_equal 6500.0, peg.trace_elements_ppm["F"]
      assert_equal 2500.0, peg.trace_elements_ppm["S"]
      assert_equal 1450.0, peg.trace_elements_ppm["Rb"]
      assert_equal 180.0, peg.trace_elements_ppm["Cs"]

      dunite = ReferenceAssay.find_by!(source: "georoc", external_id: "GEO-DIRECT-2")
      assert_equal "igneous_rock", dunite.sample_media
      assert_in_delta 1.45, dunite.minor_oxides["Cr2O3"], 0.001
      assert_in_delta 0.04, dunite.minor_oxides["ZrO2"], 0.001

      # Re-import idempotently in bulk mode
      second = Ingestion::GeorocCsvImporter.new(StringIO.new(csv), bulk: true).call
      assert_equal 2, second.imported
      assert_equal 0, second.created
      assert_equal 2, second.updated
      assert_equal 2, ReferenceAssay.by_source("georoc").count
    end

    test "geochem:import_georoc rake task imports a GEOROC CSV cleanly" do
      Rails.application.load_tasks if Rake::Task.tasks.empty?
      task = Rake::Task["geochem:import_georoc"]
      task.reenable

      Tempfile.create([ "georoc_rake", ".csv" ]) do |f|
        f.write("SAMPLE NAME,ROCK NAME,LATITUDE (MIN.),LONGITUDE (MIN.),SIO2(WT%),AL2O3(WT%),FEOT(WT%),CR(PPM)\n")
        f.write("RAKE-GEO-1,BASALT,46.20,-122.18,50.8,14.5,11.8,310\n")
        f.write("References:\n[1] Test Ref\n")
        f.flush

        assert_output(/GEOROC import complete: imported=1/) do
          task.invoke(f.path)
        end
      end

      assay = ReferenceAssay.find_by!(source: "georoc", external_id: "RAKE-GEO-1")
      assert_equal "igneous_rock", assay.sample_media
      assert_equal 310.0, assay.trace_elements_ppm["Cr"]
    end
  end
end
