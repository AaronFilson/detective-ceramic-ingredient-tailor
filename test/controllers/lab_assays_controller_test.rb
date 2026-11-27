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
