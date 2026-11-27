# frozen_string_literal: true

require "test_helper"
require "stringio"

module Lab
  class VerifiedAssayImporterTest < ActiveSupport::TestCase
    setup do
      @geologic_unit = GeologicUnit.create!(
        macrostrat_id: 901_234,
        name: "Vashon Glacial Drift",
        strat_name: "Vashon Drift",
        age: "Pleistocene",
        lithology: { "lith" => "glacial till, clay, silt" }
      )
      @sample = UserSample.create!(
        title: "Tacoma Glacial Bank Clay",
        material_category: :wild_clay,
        latitude: 47.2529,
        longitude: -122.4443,
        geologic_unit: @geologic_unit
      )
      @heuristic_assay = @sample.assay_results.create!(
        source_type: :spatial_heuristic_estimate,
        oxides: {
          "SiO2" => 60.0, "Al2O3" => 18.0, "Fe2O3" => 5.5, "CaO" => 2.5,
          "MgO" => 2.0, "Na2O" => 1.5, "K2O" => 2.5, "TiO2" => 0.8,
          "P2O5" => 0.1, "MnO" => 0.1, "LOI" => 7.0
        },
        oxide_ranges: {
          "SiO2"  => { "min" => 56.0, "q1" => 58.0, "median" => 60.0, "q3" => 62.0, "max" => 65.0, "iqr" => 4.0 },
          "Al2O3" => { "min" => 15.0, "q1" => 16.5, "median" => 18.0, "q3" => 19.5, "max" => 21.0, "iqr" => 3.0 },
          "Fe2O3" => { "min" => 3.5,  "q1" => 4.5,  "median" => 5.5,  "q3" => 6.5,  "max" => 7.5,  "iqr" => 2.0 },
          "CaO"   => { "min" => 1.0,  "q1" => 1.8,  "median" => 2.5,  "q3" => 3.5,  "max" => 4.5,  "iqr" => 1.7 },
          "MgO"   => { "min" => 1.0,  "q1" => 1.5,  "median" => 2.0,  "q3" => 2.5,  "max" => 3.5,  "iqr" => 1.0 },
          "Na2O"  => { "min" => 0.5,  "q1" => 1.0,  "median" => 1.5,  "q3" => 2.0,  "max" => 2.5,  "iqr" => 1.0 },
          "K2O"   => { "min" => 1.5,  "q1" => 2.0,  "median" => 2.5,  "q3" => 3.0,  "max" => 3.5,  "iqr" => 1.0 },
          "TiO2"  => { "min" => 0.4,  "q1" => 0.6,  "median" => 0.8,  "q3" => 1.0,  "max" => 1.2,  "iqr" => 0.4 },
          "P2O5"  => { "min" => 0.02, "q1" => 0.06, "median" => 0.1,  "q3" => 0.18, "max" => 0.3,  "iqr" => 0.12 },
          "MnO"   => { "min" => 0.02, "q1" => 0.06, "median" => 0.1,  "q3" => 0.15, "max" => 0.25, "iqr" => 0.09 },
          "LOI"   => { "min" => 5.0,  "q1" => 6.0,  "median" => 7.0,  "q3" => 8.5,  "max" => 10.0, "iqr" => 2.5 }
        },
        umf_formula: Chemistry::UmfCalculator.call(
          "SiO2" => 60.0, "Al2O3" => 18.0, "Fe2O3" => 5.5, "CaO" => 2.5,
          "MgO" => 2.0, "Na2O" => 1.5, "K2O" => 2.5, "TiO2" => 0.8,
          "P2O5" => 0.1, "MnO" => 0.1, "LOI" => 7.0
        ),
        confidence_score: 0.65,
        reasoning_log: [ "Spatial baseline heuristic." ]
      )
    end

    test "imports manual oxides hash, normalizes to exact 100.00%, computes UMF, and compares to heuristic" do
      result = VerifiedAssayImporter.call(
        user_sample: @sample,
        source_type: :verified_lab_xrf,
        oxides: {
          "SiO2" => "62.4",
          "Al2O3" => "18.1",
          "Fe2O3" => "4.9",
          "CaO" => "1.8",
          "MgO" => "1.6",
          "Na2O" => "1.1",
          "K2O" => "2.4",
          "TiO2" => "0.85",
          "P2O5" => "0.12",
          "MnO" => "0.08",
          "LOI" => "6.15"
        },
        lab_name: "WSU GeoAnalytical Lab",
        lab_report_ref: "WSU-2026-101"
      )

      assert result.success?, "Expected success, got errors: #{result.errors.inspect}"
      assert_empty result.errors
      assert_nil result.reference_assay

      assay = result.assay_result
      assert assay.persisted?
      assert_equal "verified_lab_xrf", assay.source_type
      assert assay.verified_lab?
      assert_in_delta 0.98, assay.confidence_score.to_f, 0.0001
      assert_equal "WSU GeoAnalytical Lab", assay.lab_name
      assert_equal "WSU-2026-101", assay.lab_report_ref
      assert_equal false, assay.promoted_to_reference

      # Exact 100.00% normalization across all 11 canonical oxides
      assert_equal CeramicOxides::KEYS.sort, assay.oxides.keys.sort
      assert_in_delta 100.0, assay.oxides.values.sum, 0.0001

      # Seger UMF computation
      assert_in_delta 1.0, assay.umf_formula["flux_total"].to_f, 0.001
      assert_operator assay.umf_formula["si_al_ratio"].to_f, :>, 5.0
      assert_operator assay.umf_formula["equivalent_weight"].to_f, :>, 0.0

      # Comparison & reasoning log
      assert_not_nil result.comparison
      assert_equal 11, result.comparison[:per_oxide].size
      assert_equal 11, result.comparison[:in_range_total]
      assert_operator result.comparison[:mae], :>, 0.0
      assert_operator result.comparison[:rmse], :>=, result.comparison[:mae]
      assert assay.reasoning_log.any? { |entry| entry.include?("WSU GeoAnalytical Lab") && entry.include?("100.00%") }
      assert assay.reasoning_log.any? { |entry| entry.include?("MAE") && entry.include?("RMSE") }
    end

    test "parses horizontal WSU GeoAnalytical CSV with preamble and converts FeO* to Fe2O3" do
      wsu_csv = <<~CSV
        WSU GeoAnalytical Lab - Major Elements XRF
        Unnormalized Major Elements (Weight %):
        Sample,SiO2,TiO2,Al2O3,FeO*,MnO,MgO,CaO,Na2O,K2O,P2O5,LOI
        TAC-01,61.20,0.82,17.80,4.50,0.09,1.75,2.10,1.40,2.35,0.14,7.35
      CSV

      result = VerifiedAssayImporter.call(
        user_sample: @sample,
        source_type: :verified_lab_xrf,
        csv_file: StringIO.new(wsu_csv),
        lab_name: "WSU GeoAnalytical"
      )

      assert result.success?, "Expected WSU CSV import to succeed: #{result.errors.inspect}"
      assay = result.assay_result
      assert_in_delta 100.0, assay.oxides.values.sum, 0.0001

      # FeO* 4.50 * 1.1113 = 5.00085 before exact 100% scaling (total ~100.00085)
      expected_fe2o3 = (4.50 * CeramicOxides::FEO_TO_FE2O3_FACTOR / 100.00085 * 100.0).round(2)
      assert_in_delta expected_fe2o3, assay.oxides["Fe2O3"], 0.05
      assert assay.reasoning_log.any? { |line| line.include?("FeO/FeOT") }
    end

    test "parses horizontal Actlabs ICP-MS CSV skipping Unit Symbol, Detection Limit, and Analysis Method rows" do
      actlabs_csv = <<~CSV
        Report Number: A26-04412
        Date: 2026-11-20
        Analyte Symbol,SiO2,Al2O3,Fe2O3(T),MnO,MgO,CaO,Na2O,K2O,TiO2,P2O5,LOI,Total
        Unit Symbol,%,%,%,%,%,%,%,%,%,%,%,%
        Detection Limit,0.01,0.01,0.01,0.001,0.01,0.01,0.01,0.01,0.001,0.01,,0.01
        Analysis Method,FUS-ICP,FUS-ICP,FUS-ICP,FUS-ICP,FUS-ICP,FUS-ICP,FUS-ICP,FUS-ICP,FUS-ICP,FUS-ICP,GRAV,FUS-ICP
        Tacoma-Clay-A,63.10,17.40,4.82,0.072,1.55,1.90,1.25,2.45,0.785,<0.01,6.50,99.83
      CSV

      result = VerifiedAssayImporter.call(
        user_sample: @sample,
        source_type: :verified_lab_icpms,
        csv_file: actlabs_csv,
        lab_name: "Actlabs",
        lab_report_ref: "A26-04412"
      )

      assert result.success?, "Expected Actlabs CSV import to succeed: #{result.errors.inspect}"
      assay = result.assay_result
      assert_equal "verified_lab_icpms", assay.source_type
      assert_in_delta 100.0, assay.oxides.values.sum, 0.0001
      assert_in_delta 63.21, assay.oxides["SiO2"], 0.1
      assert_in_delta 4.83, assay.oxides["Fe2O3"], 0.1
      assert_equal 0.0, assay.oxides["P2O5"]
    end

    test "parses vertical 2-column Oxide,Wt% CSV (Orton / generic) with BOM and % signs" do
      orton_csv = "\uFEFFOxide,Wt%\nSiO2,62.50%\nAl2O3,19.00%\nFe2O3,4.20%\nCaO,1.50%\nMgO,1.20%\nNa2O,0.90%\nK2O,2.60%\nTiO2,0.90%\nP2O5,0.10%\nMnO,0.05%\nLoss on Ignition,7.05%\nTotal,100.00%\n"

      result = VerifiedAssayImporter.call(
        user_sample: @sample,
        csv_file: StringIO.new(orton_csv),
        lab_name: "Orton Materials Testing"
      )

      assert result.success?, "Expected vertical CSV import to succeed: #{result.errors.inspect}"
      assay = result.assay_result
      assert_in_delta 100.0, assay.oxides.values.sum, 0.0001
      assert_in_delta 62.50, assay.oxides["SiO2"], 0.01
      assert_in_delta 19.00, assay.oxides["Al2O3"], 0.01
      assert_in_delta 7.05, assay.oxides["LOI"], 0.01
    end

    test "parses vertical multi-column report without mistaking detection limits for missing results" do
      vertical_actlabs = <<~TSV
        Analyte Symbol\tUnit Symbol\tDetection Limit\tResult
        SiO2\t%\t0.01\t64.00
        Al2O3\t%\t0.01\t18.50
        FeOT\t%\t0.01\t3.60
        CaO\t%\t0.01\t1.50
        MgO\t%\t0.01\t1.20
        Na2O\t%\t0.01\t1.10
        K2O\t%\t0.01\t2.50
        TiO2\t%\t0.01\t0.80
        P2O5\t%\t0.01\tND
        MnO\t%\t0.01\t<0.01
        LOI\t%\t0.01\t6.40
      TSV

      result = VerifiedAssayImporter.call(
        user_sample: @sample,
        csv_file: vertical_actlabs
      )

      assert result.success?, "Expected TSV vertical import to succeed: #{result.errors.inspect}"
      assay = result.assay_result
      assert_in_delta 100.0, assay.oxides.values.sum, 0.0001
      assert_equal 0.0, assay.oxides["P2O5"]
      assert_equal 0.0, assay.oxides["MnO"]
      assert_in_delta 4.00, assay.oxides["Fe2O3"], 0.05
    end

    test "compare computes exact MAE, RMSE, per-oxide deltas, within_range counts, and Si:Al ratios" do
      lab_assay = @sample.assay_results.build(
        source_type: :verified_lab_xrf,
        oxides: {
          "SiO2" => 62.0,   # delta +2.0 (in range 56..65)
          "Al2O3" => 17.0,  # delta -1.0 (in range 15..21)
          "Fe2O3" => 8.5,   # delta +3.0 (OUTSIDE 3.5..7.5)
          "CaO" => 1.5,     # delta -1.0 (in range 1..4.5)
          "MgO" => 1.0,     # delta -1.0 (in range 1..3.5)
          "Na2O" => 1.5,    # delta  0.0 (in range 0.5..2.5)
          "K2O" => 2.5,     # delta  0.0 (in range 1.5..3.5)
          "TiO2" => 0.8,    # delta  0.0 (in range 0.4..1.2)
          "P2O5" => 0.1,    # delta  0.0 (in range 0.02..0.3)
          "MnO" => 0.1,     # delta  0.0 (in range 0.02..0.25)
          "LOI" => 5.0      # delta -2.0 (in range 5..10)
        }
      )

      comparison = VerifiedAssayImporter.compare(@heuristic_assay, lab_assay)
      assert_not_nil comparison

      # Sum abs deltas = 2 + 1 + 3 + 1 + 1 + 0 + 0 + 0 + 0 + 0 + 2 = 10.0; MAE = 10/11 = 0.91
      # Sum sq deltas  = 4 + 1 + 9 + 1 + 1 + 0 + 0 + 0 + 0 + 0 + 4 = 20.0; RMSE = sqrt(20/11) = 1.35
      assert_in_delta 0.91, comparison[:mae], 0.001
      assert_in_delta 1.35, comparison[:rmse], 0.001
      assert_equal 10, comparison[:in_range_count]
      assert_equal 11, comparison[:in_range_total]

      sio2_row = comparison[:per_oxide].find { |r| r[:oxide] == "SiO2" }
      assert_equal 60.0, sio2_row[:heuristic]
      assert_equal 62.0, sio2_row[:lab]
      assert_equal 2.0, sio2_row[:delta]
      assert_equal 2.0, sio2_row[:abs_error]
      assert_equal true, sio2_row[:within_range]

      fe_row = comparison[:per_oxide].find { |r| r[:oxide] == "Fe2O3" }
      assert_equal 3.0, fe_row[:delta]
      assert_equal false, fe_row[:within_range]

      assert_operator comparison[:si_al_lab], :>, comparison[:si_al_heuristic]
      assert_nil VerifiedAssayImporter.compare(nil, lab_assay)
      assert_nil VerifiedAssayImporter.compare(@heuristic_assay, nil)
    end

    test "promotes verified lab assay to ReferenceAssay and is idempotent on re-upload" do
      first = nil
      assert_difference -> { ReferenceAssay.count }, 1 do
        first = VerifiedAssayImporter.call(
          user_sample: @sample,
          source_type: :verified_lab_xrf,
          oxides: { "SiO2" => 61.5, "Al2O3" => 18.5, "Fe2O3" => 5.0, "CaO" => 2.0, "MgO" => 1.8, "Na2O" => 1.4, "K2O" => 2.5, "LOI" => 7.3 },
          lab_name: "WSU GeoAnalytical",
          lab_report_ref: "WSU-1",
          promote_to_reference: true
        )
      end

      assert first.success?
      ref = first.reference_assay
      assert_not_nil ref
      assert_equal "community_verified_xrf", ref.source
      assert_equal "sample-#{@sample.id}-verified_lab_xrf", ref.external_id
      assert_equal "glacial_clay", ref.rock_type
      assert_in_delta 47.2529, ref.latitude, 0.0001
      assert_in_delta(-122.4443, ref.longitude, 0.0001)
      assert_equal @sample.title, ref.raw_metadata["sample_title"]
      assert_equal "WSU GeoAnalytical", ref.raw_metadata["lab_name"]
      assert_equal "Vashon Glacial Drift", ref.raw_metadata["geologic_unit"]
      assert_equal true, first.assay_result.promoted_to_reference
      assert_equal ref.id, first.assay_result.reference_assay_id

      # Re-uploading for the same sample + source_type updates ReferenceAssay in place (idempotent)
      second = nil
      assert_no_difference -> { ReferenceAssay.count } do
        second = VerifiedAssayImporter.call(
          user_sample: @sample,
          source_type: :verified_lab_xrf,
          oxides: { "SiO2" => 63.0, "Al2O3" => 17.5, "Fe2O3" => 4.5, "CaO" => 2.0, "MgO" => 1.8, "Na2O" => 1.4, "K2O" => 2.5, "LOI" => 7.3 },
          lab_name: "WSU GeoAnalytical",
          lab_report_ref: "WSU-1-REV",
          promote_to_reference: "1"
        )
      end

      assert second.success?
      assert_equal ref.id, second.reference_assay.id
      assert_in_delta 63.0, ref.reload.oxides["SiO2"], 0.05
      assert_equal "WSU-1-REV", ref.raw_metadata["lab_report_ref"]
      assert_nil first.assay_result.reload.reference_assay_id
      assert_equal false, first.assay_result.promoted_to_reference
      assert_equal ref.id, second.assay_result.reference_assay_id
    end

    test "skips spatial atlas promotion gracefully when sample has no GPS coordinates" do
      coordless = UserSample.create!(title: "Studio Mystery Clay", material_category: :wild_clay)

      result = nil
      assert_no_difference -> { ReferenceAssay.count } do
        result = VerifiedAssayImporter.call(
          user_sample: coordless,
          source_type: :verified_lab_icpms,
          oxides: { "SiO2" => 60.0, "Al2O3" => 20.0, "Fe2O3" => 4.0, "CaO" => 2.0, "K2O" => 3.0, "LOI" => 11.0 },
          promote_to_reference: true
        )
      end

      assert result.success?
      assert_nil result.reference_assay
      assert_equal false, result.assay_result.promoted_to_reference
      assert result.assay_result.reasoning_log.any? { |line| line.include?("no GPS coordinates") }
    end

    test "returns validation errors without persisting on invalid inputs" do
      assert_no_difference -> { AssayResult.count } do
        empty = VerifiedAssayImporter.call(user_sample: @sample, oxides: {})
        assert_not empty.success?
        assert empty.errors.any?

        loi_only = VerifiedAssayImporter.call(user_sample: @sample, oxides: { "LOI" => "10.0" })
        assert_not loi_only.success?
        assert loi_only.errors.any?

        negative = VerifiedAssayImporter.call(user_sample: @sample, oxides: { "SiO2" => "-5", "Al2O3" => "18" })
        assert_not negative.success?
        assert negative.errors.any? { |e| e.include?("non-negative") }

        bad_source = VerifiedAssayImporter.call(
          user_sample: @sample,
          source_type: :spatial_heuristic_estimate,
          oxides: { "SiO2" => "60", "Al2O3" => "20" }
        )
        assert_not bad_source.success?
        assert bad_source.errors.any? { |e| e.include?("Source type") }

        garbage_csv = VerifiedAssayImporter.call(user_sample: @sample, csv_file: "foo,bar\n1,2\n")
        assert_not garbage_csv.success?
        assert garbage_csv.errors.any?

        unsaved = VerifiedAssayImporter.call(user_sample: UserSample.new(title: "Unsaved"), oxides: { "SiO2" => "60", "Al2O3" => "20" })
        assert_not unsaved.success?
      end
    end
  end
end
