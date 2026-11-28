# frozen_string_literal: true

class LabAssaysController < ApplicationController
  PERMITTED_OXIDE_KEYS = (CeramicOxides::KEYS + %w[FeO FeOT Fe2O3T]).freeze
  ATLAS_PRIVACY_ERROR = "Please confirm your dig-site coordinate privacy choice (Exact GPS or ~2 km Fuzzed) before contributing to the Regional Spatial Atlas."

  before_action :set_sample

  def create
    permitted = lab_assay_params
    if atlas_privacy_confirmation_missing?(permitted)
      @assay_result = @sample.latest_assay_result
      @heuristic_assay = @sample.latest_heuristic_assay_result
      @verified_lab_assay = @sample.latest_verified_lab_assay
      @lab_errors = [ ATLAS_PRIVACY_ERROR ]
      return render_create_errors
    end

    coordinate_privacy = permitted[:coordinate_privacy].presence || "exact"
    csv_upload = permitted[:csv_file]
    csv_upload = nil unless csv_upload.respond_to?(:read)

    @result = if pxrf_submission?(permitted)
      Lab::PxrfCsvImporter.call(
        user_sample: @sample,
        csv_file: csv_upload,
        dry_weight_g: permitted[:dry_weight_g],
        fired_weight_g: permitted[:fired_weight_g],
        measured_loi_pct: permitted[:measured_loi_pct],
        lab_name: permitted[:lab_name],
        lab_report_ref: permitted[:lab_report_ref],
        promote_to_reference: permitted[:promote_to_reference],
        coordinate_privacy: coordinate_privacy,
        promoted_by_user: current_user
      )
    else
      Lab::VerifiedAssayImporter.call(
        user_sample: @sample,
        source_type: permitted[:source_type].presence || :verified_lab_xrf,
        oxides: permitted[:oxides]&.to_h,
        csv_file: csv_upload,
        lab_name: permitted[:lab_name],
        lab_report_ref: permitted[:lab_report_ref],
        promote_to_reference: permitted[:promote_to_reference],
        coordinate_privacy: coordinate_privacy,
        promoted_by_user: current_user
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
      render_create_errors
    end
  end

  def destroy
    @lab_assay = @sample.assay_results
      .where(source_type: [ :verified_lab_xrf, :verified_lab_icpms ])
      .find(params[:id])

    AssayResult.transaction do
      ref_assay_id = @lab_assay.reference_assay_id
      was_promoted = @lab_assay.promoted_to_reference?
      @lab_assay.destroy!

      if was_promoted && ref_assay_id.present? &&
          AssayResult.where(reference_assay_id: ref_assay_id).none?
        ref_assay = ReferenceAssay.find_by(id: ref_assay_id)
        ref_assay.destroy! if ref_assay&.source.to_s.start_with?("community_verified_")
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
    @sample = scoped_samples.find(params[:sample_id])
  end

  def pxrf_submission?(permitted)
    permitted[:source_type].to_s == "pxrf" || permitted[:analysis_method].to_s == "pxrf"
  end

  def atlas_privacy_confirmation_missing?(permitted)
    return false if @sample.latitude.blank? || @sample.longitude.blank?

    bool = ActiveModel::Type::Boolean.new
    return false unless bool.cast(permitted[:promote_to_reference])
    return false unless permitted[:privacy_prompt_shown].to_s == "1"

    !bool.cast(permitted[:atlas_privacy_confirmed]) ||
      !ReferenceAssay::COORDINATE_PRIVACY_MODES.include?(permitted[:coordinate_privacy].to_s)
  end

  def render_create_errors
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

  def lab_assay_params
    raw = params.fetch(:lab_assay, {})
    return {} unless raw.respond_to?(:permit)

    raw.permit(
      :source_type,
      :analysis_method,
      :lab_name,
      :lab_report_ref,
      :promote_to_reference,
      :coordinate_privacy,
      :privacy_prompt_shown,
      :atlas_privacy_confirmed,
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
      privacy_suffix = result.reference_assay.coordinate_privacy == "fuzzed_2km" ? " (~2 km fuzzed coordinates)" : ""
      "#{method_label} assay logged and promoted to the Regional Spatial Atlas#{privacy_suffix}."
    else
      "#{method_label} assay logged and normalized to 100.00%."
    end
  end
end
