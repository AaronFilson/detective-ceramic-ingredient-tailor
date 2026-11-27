# frozen_string_literal: true

class SampleExportsController < ActionController::API
  before_action :set_sample

  # GET /samples/:id/export/glazecalc.json
  def glazecalc
    assay_result = @sample.latest_assay_result
    return render_not_found("No assay result available for sample #{@sample.id}") if assay_result.nil?

    payload = if params[:envelope].to_s == "export"
      Exporters::GlazecalcMaterialSerializer.export_envelope(assay_result)
    else
      Exporters::GlazecalcMaterialSerializer.call(assay_result)
    end
    filename = params[:envelope].to_s == "export" ? "#{sample_slug}-glazecalc-import.json" : "#{sample_slug}-glazecalc.json"
    render_export_json(payload, filename: filename, set_inline_filename: false)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  # GET /samples/:id/export/glaze_vault.json
  def glaze_vault
    assay_result = @sample.latest_assay_result
    return render_not_found("No assay result available for sample #{@sample.id}") if assay_result.nil?

    payload = Exporters::GlazeVaultSerializer.call(assay_result)
    render_export_json(payload, filename: "#{sample_slug}-glaze-vault.json", set_inline_filename: true)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  private

  def set_sample
    @sample = UserSample.includes(:geologic_unit, :field_observations).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_not_found("Sample not found")
  end

  def render_export_json(payload, filename:, set_inline_filename:)
    if download_requested?
      response.headers["Content-Disposition"] = %(attachment; filename="#{filename}")
    elsif set_inline_filename
      response.headers["Content-Disposition"] = %(inline; filename="#{filename}")
    end

    render json: JSON.pretty_generate(payload)
  end

  def download_requested?
    params[:download].present? && ActiveModel::Type::Boolean.new.cast(params[:download])
  end

  def sample_slug
    @sample.title.to_s.parameterize.presence || "sample-#{@sample.id}"
  end

  def render_not_found(message)
    render json: { error: message }, status: :not_found
  end
end
