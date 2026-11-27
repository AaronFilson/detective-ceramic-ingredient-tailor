# frozen_string_literal: true

require "test_helper"

class LabAssaysControllerTest < ActionDispatch::IntegrationTest
  setup do
    @sample = UserSample.create!(
      title: "Puget Glacial Wild Clay",
      material_category: :wild_clay,
      latitude: 47.2529,
      longitude: -122.4443
    )
    @heuristic_assay = SamplesController.estimate_sample(@sample)
  end

  test "POST /samples/:sample_id/lab_assays with manual oxides via Turbo Stream updates both panels with comparison table" do
    assert_difference -> { @sample.assay_results.count }, 1 do
      post sample_lab_assays_path(@sample),
        params: {
          lab_assay: {
            source_type: "verified_lab_xrf",
            lab_name: "WSU GeoAnalytical Lab",
            lab_report_ref: "WSU-2026-0412",
            oxides: {
              "SiO2" => "62.80",
              "Al2O3" => "17.90",
              "Fe2O3" => "4.95",
              "CaO" => "1.85",
              "MgO" => "1.65",
              "Na2O" => "1.30",
              "K2O" => "2.45",
              "TiO2" => "0.85",
              "P2O5" => "0.12",
              "MnO" => "0.08",
              "LOI" => "6.05"
            }
          }
        },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type

    assert_includes response.body, '<turbo-stream action="replace" target="assay_estimate_panel">'
    assert_includes response.body, '<turbo-stream action="replace" target="lab_calibration_panel">'
    assert_includes response.body, "Verified Lab XRF"
    assert_includes response.body, "98% Confidence"
    assert_includes response.body, "WSU GeoAnalytical Lab"
    assert_includes response.body, "WSU-2026-0412"
    assert_includes response.body, "data-lab-comparison-table"
    assert_includes response.body, "MAE"
    assert_includes response.body, "RMSE"

    latest = @sample.reload.latest_assay_result
    assert latest.verified_lab_xrf?
    assert_in_delta 100.0, latest.oxides.values.sum, 0.001
    assert_equal false, latest.promoted_to_reference
  end

  test "POST /samples/:sample_id/lab_assays with CSV upload and promote_to_reference creates ReferenceAssay" do
    csv_body = <<~CSV
      Sample,SiO2,Al2O3,FeO*,CaO,MgO,Na2O,K2O,TiO2,P2O5,MnO,LOI
      PUGET-1,61.50,18.40,4.50,2.10,1.70,1.25,2.55,0.82,0.13,0.08,6.47
    CSV

    tempfile = Tempfile.new([ "wsu_report", ".csv" ])
    tempfile.write(csv_body)
    tempfile.rewind
    uploaded = Rack::Test::UploadedFile.new(tempfile.path, "text/csv", original_filename: "wsu_report.csv")

    assert_difference -> { ReferenceAssay.count }, 1 do
      assert_difference -> { @sample.assay_results.count }, 1 do
        post sample_lab_assays_path(@sample),
          params: {
            lab_assay: {
              source_type: "verified_lab_icpms",
              lab_name: "Actlabs",
              lab_report_ref: "ACT-991",
              promote_to_reference: "1",
              csv_file: uploaded
            }
          },
          headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end
    end

    assert_response :success
    assert_includes response.body, "Verified Lab ICP-MS"
    assert_includes response.body, "Promoted to Spatial Atlas"

    lab_assay = @sample.reload.latest_verified_lab_assay
    assert lab_assay.verified_lab_icpms?
    assert lab_assay.promoted_to_reference?
    assert_not_nil lab_assay.reference_assay
    assert_equal "community_verified_icpms", lab_assay.reference_assay.source
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  test "POST /samples/:sample_id/lab_assays with handheld pXRF CSV and kiln LOI weights updates via Turbo Stream" do
    pxrf_csv = <<~CSV
      Sample ID,Si (%),Si Err,Al (%),Fe (%),Ca (%),Mg (%),K (%),Ti (%),Rb (ppm),Ba (ppm),Zr (ppm),As (ppm)
      PXRF-BLUFF-1,28.90,0.20,9.50,3.20,1.35,0.95,2.80,0.45,420,900,850,65
    CSV

    tempfile = Tempfile.new([ "bruker_pxrf", ".csv" ])
    tempfile.write(pxrf_csv)
    tempfile.rewind
    uploaded = Rack::Test::UploadedFile.new(tempfile.path, "text/csv", original_filename: "bruker_pxrf.csv")

    assert_difference -> { @sample.assay_results.count }, 1 do
      post sample_lab_assays_path(@sample),
        params: {
          lab_assay: {
            source_type: "pxrf",
            lab_name: "Bruker S1 TITAN",
            dry_weight_g: "100.0",
            fired_weight_g: "91.5",
            csv_file: uploaded
          }
        },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, '<turbo-stream action="replace" target="assay_estimate_panel">'
    assert_includes response.body, '<turbo-stream action="replace" target="lab_calibration_panel">'
    assert_includes response.body, "Handheld pXRF"
    assert_includes response.body, "90% Confidence"
    assert_includes response.body, "data-pxrf-badge"
    assert_includes response.body, "data-lab-minor-trace-summary"
    assert_includes response.body, "data-studio-kiln-loi-calculator"

    latest = @sample.reload.latest_assay_result
    assert_equal "pxrf", latest.analysis_method
    assert_in_delta 0.90, latest.confidence_score.to_f, 0.001
    assert_in_delta 8.50, latest.oxides["LOI"], 0.01
    assert_in_delta 100.0, latest.oxides.values.sum, 0.01
    assert_in_delta 420.0, latest.trace_elements_ppm["Rb"], 0.1
    assert latest.minor_oxides.key?("BaO")
    assert latest.minor_oxides.key?("ZrO2")
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  test "POST /samples/:sample_id/lab_assays with pXRF CSV and promote_to_reference as HTML redirects cleanly" do
    pxrf_csv = "Sample,Si (%),Al (%),Fe (%),Ca (%),K (%),Rb (ppm)\nPXRF-2,30.0,9.5,2.5,1.2,3.1,180\n"
    tempfile = Tempfile.new([ "vanta_pxrf", ".csv" ])
    tempfile.write(pxrf_csv)
    tempfile.rewind
    uploaded = Rack::Test::UploadedFile.new(tempfile.path, "text/csv", original_filename: "vanta_pxrf.csv")

    assert_difference -> { ReferenceAssay.count }, 1 do
      post sample_lab_assays_path(@sample),
        params: {
          lab_assay: {
            source_type: "pxrf",
            measured_loi_pct: "7.2",
            promote_to_reference: "1",
            csv_file: uploaded
          }
        }
    end

    assert_redirected_to sample_path(@sample)
    assert_match(/Handheld pXRF/, flash[:notice])
    assert_match(/Spatial Atlas/, flash[:notice])
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  test "POST /samples/:sample_id/lab_assays rejects invalid pXRF kiln weights with 422 Turbo Stream" do
    pxrf_csv = "Sample,Si (%),Al (%),K (%)\nS1,30.0,10.0,3.0\n"
    tempfile = Tempfile.new([ "bad_loi", ".csv" ])
    tempfile.write(pxrf_csv)
    tempfile.rewind
    uploaded = Rack::Test::UploadedFile.new(tempfile.path, "text/csv", original_filename: "bad_loi.csv")

    assert_no_difference -> { @sample.assay_results.count } do
      post sample_lab_assays_path(@sample),
        params: {
          lab_assay: {
            source_type: "pxrf",
            dry_weight_g: "50.0",
            fired_weight_g: "60.0",
            csv_file: uploaded
          }
        },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Fired weight cannot exceed dry weight"
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  test "renders lab_assays/_hazard_alerts partial cleanly with danger badges, food-safe caution, and K/Rb pill" do
    pxrf_assay = @sample.assay_results.create!(
      source_type: :verified_lab_xrf,
      analysis_method: "pxrf",
      oxides: { "SiO2" => 65.0, "Al2O3" => 18.0, "K2O" => 6.0, "Na2O" => 4.0, "CaO" => 1.5, "Fe2O3" => 1.5, "LOI" => 4.0 },
      minor_oxides: { "BaO" => 2.8, "SO3" => 0.4 },
      trace_elements_ppm: { "Rb" => 480.0, "As" => 80.0 }
    )

    html = ApplicationController.render(
      partial: "lab_assays/hazard_alerts",
      locals: { sample: @sample, assay_result: pxrf_assay, nearby_minerals: [], nearby_xrd: {} }
    )

    assert_includes html, "data-hazard-alerts"
    assert_includes html, 'data-highest-severity="danger"'
    assert_includes html, "data-food-safe-caution"
    assert_includes html, "data-krb-pathfinder"
    assert_includes html, "LCT Li Signal"
    assert_includes html, "Elevated Arsenic"
    assert_includes html, "Barium Toxicity"
    assert_includes html, "Handheld pXRF Light-Element"

    clear_html = ApplicationController.render(
      partial: "lab_assays/hazard_alerts",
      locals: { sample: @sample, assay_result: @heuristic_assay, nearby_minerals: [], nearby_xrd: {} }
    )
    assert_includes clear_html, 'data-hazard-status="clear"'
  end

  test "POST /samples/:sample_id/lab_assays as HTML redirects to sample workbench" do
    post sample_lab_assays_path(@sample),
      params: {
        lab_assay: {
          source_type: "verified_lab_xrf",
          lab_name: "Orton",
          oxides: { "SiO2" => "61.0", "Al2O3" => "19.0", "Fe2O3" => "5.0", "CaO" => "2.0", "K2O" => "3.0", "LOI" => "10.0" }
        }
      }

    assert_redirected_to sample_path(@sample)
    assert_match(/Verified Lab XRF/, flash[:notice])
  end

  test "DELETE /samples/:sample_id/lab_assays/:id removes lab assay and cleans up promoted ReferenceAssay" do
    import_result = Lab::VerifiedAssayImporter.call(
      user_sample: @sample,
      source_type: :verified_lab_xrf,
      oxides: { "SiO2" => 62.0, "Al2O3" => 18.0, "Fe2O3" => 5.0, "CaO" => 2.0, "MgO" => 1.5, "Na2O" => 1.2, "K2O" => 2.5, "LOI" => 7.8 },
      lab_name: "WSU GeoAnalytical",
      promote_to_reference: true
    )
    lab_assay = import_result.assay_result
    ref_assay = import_result.reference_assay
    assert ref_assay.persisted?

    assert_difference -> { ReferenceAssay.count }, -1 do
      assert_difference -> { @sample.assay_results.count }, -1 do
        delete sample_lab_assay_path(@sample, lab_assay),
          headers: { "Accept" => "text/vnd.turbo-stream.html" }
      end
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, '<turbo-stream action="replace" target="assay_estimate_panel">'
    assert_includes response.body, '<turbo-stream action="replace" target="lab_calibration_panel">'
    assert_includes response.body, "Spatial Heuristic Estimate"
    assert_not_includes response.body, "data-verified-lab-card"

    assert_nil ReferenceAssay.find_by(id: ref_assay.id)
    assert_equal @heuristic_assay.id, @sample.reload.latest_assay_result.id
  end

  test "DELETE /samples/:sample_id/lab_assays/:id refuses to delete heuristic assay" do
    assert_no_difference -> { AssayResult.count } do
      delete sample_lab_assay_path(@sample, @heuristic_assay),
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :not_found
  end

  test "POST /samples/:sample_id/lab_assays with invalid submission returns 422 via Turbo Stream" do
    assert_no_difference -> { @sample.assay_results.count } do
      post sample_lab_assays_path(@sample),
        params: {
          lab_assay: {
            source_type: "verified_lab_xrf",
            oxides: { "SiO2" => "", "Al2O3" => "" }
          }
        },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :unprocessable_entity
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, '<turbo-stream action="replace" target="lab_calibration_panel">'
    assert_includes response.body, "Could not import verified lab assay:"
    assert_includes response.body, "open>"
  end
end
