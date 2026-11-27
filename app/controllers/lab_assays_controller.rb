# frozen_string_literal: true

class LabAssaysController < ApplicationController
  PERMITTED_OXIDE_KEYS = (CeramicOxides::KEYS + %w[FeO FeOT Fe2O3T]).freeze

  before_action :set_sample

  def create
    permitted = lab_assay_params
    @result = if pxrf_submission?(permitted)
      Lab::PxrfCsvImporter.call(
        user_sample: @sample,
        csv_file: permitted[:csv_file],
        dry_weight_g: permitted[:dry_weight_g],
        fired_weight_g: permitted[:fired_weight_g],
        measured_loi_pct: permitted[:measured_loi_pct],
        lab_name: permitted[:lab_name],
        lab_report_ref: permitted[:lab_report_ref],
        promote_to_reference: permitted[:promote_to_reference]
      )
    else
      Lab::VerifiedAssayImporter.call(
        user_sample: @sample,
        source_type: permitted[:source_type].presence || :verified_lab_xrf,
        oxides: permitted[:oxides]&.to_h,
        csv_file: permitted[:csv_file],
        lab_name: permitted[:lab_name],
        lab_report_ref: permitted[:lab_report_ref],
        promote_to_reference: permitted[:promote_to_reference]
      )
    end

    @assay_result = @sample.latest_assay_result
    @heuristic_assay = @sample.latest_heuristic_assay_result
    @verified_lab_assay = @sample.latest_verified_lab_assay

    if @result.success?
      @lab_errors = nil

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to sample_path(@sample), notice: build_create_notice(@result) }
      end
    else
      @lab_errors = @result.errors

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "lab_calibration_panel",
            partial: "lab_assays/panel",
            locals: {
              sample: @sample,
              heuristic_assay: @heuristic_assay,
              verified_lab_assay: @verified_lab_assay,
              lab_errors: @lab_errors
            }
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to sample_path(@sample), alert: @lab_errors.to_sentence
        end
      end
    end
  end

  def destroy
    @lab_assay = @sample.assay_results
      .where(source_type: [ :verified_lab_xrf, :verified_lab_icpms ])
      .find(params[:id])

    AssayResult.transaction do
      ref_assay = @lab_assay.reference_assay
      was_promoted = @lab_assay.promoted_to_reference?
      @lab_assay.destroy!

      if was_promoted && ref_assay.present? &&
          ref_assay.source.to_s.start_with?("community_verified_") &&
          AssayResult.where(reference_assay_id: ref_assay.id).none?
        ref_assay.destroy!
      end
    end

    @assay_result = @sample.latest_assay_result
    @heuristic_assay = @sample.latest_heuristic_assay_result
    @verified_lab_assay = @sample.latest_verified_lab_assay
    @lab_errors = nil

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to sample_path(@sample), notice: "Verified lab assay removed." }
    end
  end

  private

  def set_sample
    @sample = UserSample.find(params[:sample_id])
  end

  def pxrf_submission?(permitted)
    permitted[:source_type].to_s == "pxrf" || permitted[:analysis_method].to_s == "pxrf"
  end

  def lab_assay_params
    raw = params.fetch(:lab_assay, {})
    return {} unless raw.respond_to?(:permit)

    raw.permit(
      :source_type,
      :analysis_method,
      :lab_name,
      :lab_report_ref,
      :promote_to_reference,
      :csv_file,
      :dry_weight_g,
      :fired_weight_g,
      :measured_loi_pct,
      oxides: PERMITTED_OXIDE_KEYS
    )
  end

  def build_create_notice(result)
    method_label = if result.assay_result.analysis_method == "pxrf"
      "Handheld pXRF"
    elsif result.assay_result.verified_lab_icpms?
      "Verified Lab ICP-MS"
    else
      "Verified Lab XRF"
    end

    if result.reference_assay.present?
      "#{method_label} assay logged and promoted to the Regional Spatial Atlas."
    else
      "#{method_label} assay logged and normalized to 100.00%."
    end
  end
end
