# frozen_string_literal: true

require "test_helper"
require "stringio"

class Ingestion::EarthchemCsvImporterTest < ActiveSupport::TestCase
  test "imports EarthChem CSV with metadata preamble, FEOT conversion, and H2O+/CO2 volatile fallback" do
    csv = <<~CSV
      EarthChem Portal Export - Pacific Northwest Igneous Suite
      Downloaded: 2026-11-27
      SAMPLE ID,LATITUDE,LONGITUDE,ROCK NAME,SiO2 (wt%),Al2O3 (wt%),FEOT,CaO (wt%),MgO (wt%),Na2O (wt%),K2O (wt%),TiO2 (wt%),P2O5 (wt%),MnO (wt%),H2O+,CO2
      EC-CRB-01,46.9445,-119.9870,BASALT,51.2,13.9,12.2,8.8,4.7,2.8,1.2,2.4,0.4,0.2,0.8,0.3
      EC-BAD-01,46.90,-119.90,BASALT,51.2,ND,12.2,8.8,4.7,2.8,1.2,2.4,0.4,0.2,0.8,0.3
    CSV

    result = Ingestion::EarthchemCsvImporter.new(StringIO.new(csv)).call
    assert_equal 1, result.imported
    assert_equal 1, result.created
    assert_equal 1, result.skipped

    assay = ReferenceAssay.find_by!(source: "earthchem", external_id: "EC-CRB-01")
    assert_equal "basalt", assay.rock_type
    assert_in_delta 100.0, assay.oxides.values.sum, 0.01
    # FEOT (12.2) converted to Fe2O3 (12.2 * 1.1113 = 13.5579) before normalization
    assert assay.oxides["Fe2O3"] > 13.0
    # H2O+ (0.8) + CO2 (0.3) = 1.1 -> LOI ~ 1.09%
    assert_in_delta 1.1, assay.oxides["LOI"], 0.1
    assert_equal "BASALT", assay.raw_metadata["ROCK NAME"]
  end

  test "imports tab-delimited EarthChem TSV with elemental ppm columns and preserves idempotency" do
    tsv = [
      "IGSN\tLAT\tLON\tROCK TYPE\tSiO2\tAl2O3\tFe2O3T\tCaO\tTi_ppm\tMn_ppm\tLOI",
      "IGSN-9901\t47.4240\t-121.4137\tGranodiorite\t66.0\t16.0\t4.5\t4.0\t3600\t600\t0.6"
    ].join("\n")

    first = Ingestion::EarthchemCsvImporter.new(StringIO.new(tsv)).call
    assert_equal 1, first.imported
    assert_equal 1, first.created

    assay = ReferenceAssay.find_by!(source: "earthchem", external_id: "IGSN-9901")
    assert_equal "granodiorite", assay.rock_type
    assert_in_delta 100.0, assay.oxides.values.sum, 0.01
    assert assay.oxides["TiO2"] > 0.6

    second = Ingestion::EarthchemCsvImporter.new(StringIO.new(tsv)).call
    assert_equal 1, second.imported
    assert_equal 0, second.created
    assert_equal 1, second.updated
    assert_equal 1, ReferenceAssay.where(source: "earthchem", external_id: "IGSN-9901").count
  end
end
