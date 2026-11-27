# frozen_string_literal: true

require "test_helper"

module Lab
  class PxrfCsvImporterTest < ActiveSupport::TestCase
    setup do
      @sample = UserSample.create!(
        title: "Cascade Pegmatite Feldspar",
        material_category: :crushed_rock,
        latitude: 47.6205,
        longitude: -120.6615
      )
      @heuristic = @sample.assay_results.create!(
        source_type: :spatial_heuristic_estimate,
        confidence_score: 0.65,
        oxides: {
          "SiO2" => 68.0, "Al2O3" => 17.0, "Fe2O3" => 2.0, "CaO" => 1.5,
          "MgO" => 0.8, "Na2O" => 3.2, "K2O" => 5.5, "TiO2" => 0.3,
          "P2O5" => 0.1, "MnO" => 0.05, "LOI" => 1.55
        }
      )
    end

    test "imports Bruker S1 TITAN elemental CSV with studio kiln LOI, minor oxides, trace ppm, and K/Rb pathfinder" do
      bruker_csv = <<~CSV
        Instrument,Bruker S1 TITAN
        Sample ID,Si (%),Si Err,Al (%),Al Err,Fe (%),Ca (%),Mg (%),Na (%),K (%),Ti (%),P (%),Mn (%),Rb (ppm),Cs (ppm),Ba (ppm),Zr (ppm),As (ppm),Pb (ppm),S (ppm),LE (%)
        PEG-2026-01,29.50,0.22,9.80,0.18,1.10,0.85,0.25,1.80,5.20,0.12,0.08,0.04,520,85,22000,1200,72,145,2800,48.10
      CSV

      result = PxrfCsvImporter.call(
        user_sample: @sample,
        csv_file: bruker_csv,
        dry_weight_g: 100.0,
        fired_weight_g: 92.5,
        lab_name: "Bruker S1 TITAN (Studio)",
        promote_to_reference: true
      )

      assert result.success?, "Expected success, got errors: #{result.errors.inspect}"
      assert_in_delta 7.5, result.measured_loi_pct, 0.01

      assay = result.assay_result
      assert assay.persisted?
      assert assay.verified_lab_xrf?
      assert_equal "pxrf", assay.analysis_method
      assert_in_delta 0.90, assay.confidence_score.to_f, 0.001
      assert_equal "Bruker S1 TITAN (Studio)", assay.lab_name
      assert_equal "PEG-2026-01", assay.lab_report_ref

      # Exact 100.00% normalization preserving measured 7.50% studio kiln LOI
      assert_in_delta 7.50, assay.oxides["LOI"], 0.01
      assert_in_delta 100.0, assay.oxides.values.sum, 0.01
      assert assay.oxides["SiO2"] > 50.0
      assert assay.oxides["K2O"] > 5.0

      # Significant minor ceramic elements (>= 500 ppm) converted to minor_oxides
      assert_in_delta (22_000 / 10_000.0) * 1.1165, assay.minor_oxides["BaO"], 0.01
      assert_in_delta (1_200 / 10_000.0) * 1.3508, assay.minor_oxides["ZrO2"], 0.01
      assert_in_delta (2_800 / 10_000.0) * 2.4972, assay.minor_oxides["SO3"], 0.01

      # Trace elements preserved in ppm
      assert_in_delta 520.0, assay.trace_elements_ppm["Rb"], 0.1
      assert_in_delta 85.0, assay.trace_elements_ppm["Cs"], 0.1
      assert_in_delta 72.0, assay.trace_elements_ppm["As"], 0.1
      assert_in_delta 145.0, assay.trace_elements_ppm["Pb"], 0.1

      # UMF computed with minor oxides (BaO in RO fluxes, ZrO2 in RO2 glass formers, SO3 excluded)
      assert assay.umf_formula.dig("fluxes").key?("BaO")
      assert assay.umf_formula.dig("glass_formers").key?("ZrO2")
      assert_not assay.umf_formula.dig("oxides").key?("SO3")
      assert_in_delta 1.0, assay.umf_formula["flux_total"], 0.001

      # Hazard screening & K/Rb LCT pegmatite pathfinder executed
      report = result.hazard_report
      assert_not_nil report
      assert_equal :danger, report.highest_severity
      assert report.food_safe_caution?
      assert_not_nil report.k_rb_ratio
      assert report.k_rb_ratio < 160.0
      alert_codes = report.alerts.map { |a| a[:code] }
      assert_includes alert_codes, "toxic_arsenic"
      assert_includes alert_codes, "toxic_lead"
      assert_includes alert_codes, "barium_toxicity"
      assert_includes alert_codes, "sulfide_degassing"
      assert_includes alert_codes, "pxrf_light_element_blind_spot"
      assert_includes alert_codes, "lct_pegmatite_pathfinder"

      # Heuristic residual comparison computed
      assert_not_nil result.comparison
      assert result.comparison[:mae] >= 0.0

      # Promoted ReferenceAssay carries minor_oxides and trace_elements_ppm
      ref = result.reference_assay
      assert_not_nil ref
      assert_equal "community_verified_xrf", ref.source
      assert_equal "sample-#{@sample.id}-pxrf", ref.external_id
      assert_in_delta assay.minor_oxides["BaO"], ref.minor_oxides["BaO"], 0.001
      assert_in_delta 520.0, ref.trace_elements_ppm["Rb"], 0.1
    end

    test "imports Olympus Vanta CSV with Units row and <LOD tokens on anhydrous 0.82 confidence basis" do
      vanta_csv = <<~CSV
        Reading No,Si Concentration,Si Error1s,Al Concentration,Al Error1s,Fe Concentration,Ca Concentration,K Concentration,Ti Concentration,Zn Concentration,Sr Concentration,Cd Concentration,U Concentration
        Units,%,%,%,%,%,%,%,%,ppm,ppm,ppm,ppm
        VANTA-42,30.10,0.15,10.20,0.11,2.80,1.40,2.60,0.45,950,620,<LOD,14
      CSV

      result = PxrfCsvImporter.call(
        user_sample: @sample,
        csv_file: vanta_csv,
        lab_name: "Olympus Vanta M-Series"
      )

      assert result.success?, "Expected success, got errors: #{result.errors.inspect}"
      assay = result.assay_result
      assert_equal "pxrf", assay.analysis_method
      assert_in_delta 0.82, assay.confidence_score.to_f, 0.001
      assert_equal 0.0, assay.oxides["LOI"]
      assert_in_delta 100.0, assay.oxides.values.sum, 0.01
      assert_equal "VANTA-42", assay.lab_report_ref

      assert_not assay.trace_elements_ppm.key?("Cd")
      assert_in_delta 950.0, assay.trace_elements_ppm["Zn"], 0.1
      assert_in_delta 620.0, assay.trace_elements_ppm["Sr"], 0.1
      assert_in_delta (950 / 10_000.0) * 1.2447, assay.minor_oxides["ZnO"], 0.001
      assert_in_delta (620 / 10_000.0) * 1.1826, assay.minor_oxides["SrO"], 0.001
    end

    test "imports Thermo Niton CSV with Units column in ppm mode and direct measured_loi_pct" do
      niton_csv = <<~CSV
        Sample,Units,Si,Si Error,Al,Al Error,Fe,Ca,K,Rb,Sr,Cu,Bal
        NITON-9,ppm,310000,1200,95000,900,18000,12000,32000,310,200,1200,520000
      CSV

      result = PxrfCsvImporter.call(
        user_sample: @sample,
        csv_file: niton_csv,
        measured_loi_pct: 6.4
      )

      assert result.success?, "Expected success, got errors: #{result.errors.inspect}"
      assay = result.assay_result
      assert_in_delta 0.90, assay.confidence_score.to_f, 0.001
      assert_in_delta 6.40, assay.oxides["LOI"], 0.01
      assert_in_delta 100.0, assay.oxides.values.sum, 0.01
      assert_in_delta 310.0, assay.trace_elements_ppm["Rb"], 0.1
      assert_in_delta 200.0, assay.trace_elements_ppm["Sr"], 0.1
      assert_in_delta 1200.0, assay.trace_elements_ppm["Cu"], 0.1
      assert_in_delta (1200 / 10_000.0) * 1.2518, assay.minor_oxides["CuO"], 0.001
      assert_not assay.minor_oxides.key?("SrO")
    end

    test "imports Thermo Niton CSV with Units column in percent mode and converts trace % to ppm" do
      niton_pct_csv = <<~CSV
        Sample,Units,Si,Al,Fe,Ca,K,Rb,As,Bal
        NITON-PCT-1,%,30.5,9.4,1.8,1.1,4.8,0.045,0.008,52.347
      CSV

      result = PxrfCsvImporter.call(user_sample: @sample, csv_file: niton_pct_csv)
      assert result.success?, "Expected success, got errors: #{result.errors.inspect}"
      assay = result.assay_result
      assert_in_delta 450.0, assay.trace_elements_ppm["Rb"], 0.5
      assert_in_delta 80.0, assay.trace_elements_ppm["As"], 0.5
      assert_includes result.hazard_report.alerts.map { |a| a[:code] }, "toxic_arsenic"
      assert_includes result.hazard_report.alerts.map { |a| a[:code] }, "lct_pegmatite_pathfinder"
    end

    test "validates studio kiln LOI weight inputs and rejects malformed or empty CSVs" do
      valid_csv = "Sample,Si (%),Al (%),K (%)\nS1,30.0,10.0,3.5\n"

      fired_heavier = PxrfCsvImporter.call(
        user_sample: @sample,
        csv_file: valid_csv,
        dry_weight_g: 80.0,
        fired_weight_g: 85.0
      )
      assert_not fired_heavier.success?
      assert_match(/cannot exceed dry weight/i, fired_heavier.errors.join(" "))

      missing_fired = PxrfCsvImporter.call(
        user_sample: @sample,
        csv_file: valid_csv,
        dry_weight_g: 100.0
      )
      assert_not missing_fired.success?
      assert_match(/both dry weight/i, missing_fired.errors.join(" "))

      empty_csv = PxrfCsvImporter.call(user_sample: @sample, csv_file: "")
      assert_not empty_csv.success?

      unrecognized_csv = PxrfCsvImporter.call(user_sample: @sample, csv_file: "Foo,Bar\n1,2\n")
      assert_not unrecognized_csv.success?

      unsaved = UserSample.new(title: "Unsaved")
      unsaved_result = PxrfCsvImporter.call(user_sample: unsaved, csv_file: valid_csv)
      assert_not unsaved_result.success?
    end
  end
end
