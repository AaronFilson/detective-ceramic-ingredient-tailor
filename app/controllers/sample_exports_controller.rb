# frozen_string_literal: true

class SampleExportsController < ActionController::API
  include ActionController::Cookies

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
    scope = resolve_export_scope
    return if performed?

    @sample = scope.includes(:geologic_unit, :field_observations).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_not_found("Sample not found")
  end

  def resolve_export_scope
    if request.authorization.present?
      token = ApiToken.authenticate(request.authorization)
      if token.nil?
        render json: { error: "Invalid or revoked API token" }, status: :unauthorized
        return UserSample.none
      end
      return token.user.user_samples
    end

    session_id = cookies.signed[:session_id]
    if session_id.present? && (session_record = Session.includes(:user).find_by(id: session_id))
      return UserSample.for_owner(user: session_record.user, guest_token: nil)
    end

    guest_token = cookies.signed[:guest_token]
    UserSample.for_owner(user: nil, guest_token: guest_token)
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
