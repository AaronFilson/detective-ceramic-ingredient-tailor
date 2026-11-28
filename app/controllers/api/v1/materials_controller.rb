# frozen_string_literal: true

module Api
  module V1
    class MaterialsController < ActionController::API
      include ActionController::Cookies

      API_VERSION = "v1"

      before_action :resolve_api_scope!

      # GET /api/v1/materials
      def index
        samples = @scoped_materials
          .includes(:geologic_unit, :field_observations, :assay_results)
          .joins(:assay_results)
          .distinct
          .order(updated_at: :desc, id: :desc)

        materials = samples.filter_map do |sample|
          assay = latest_preloaded_assay(sample)
          next if assay.nil?

          serialize_material(sample, assay)
        rescue ArgumentError
          nil
        end

        render json: {
          "api_version" => API_VERSION,
          "count" => materials.length,
          "materials" => materials
        }
      end

      # GET /api/v1/materials/:id
      def show
        sample = @scoped_materials.includes(:geologic_unit, :field_observations).find(params[:id])
        assay = sample.latest_assay_result
        if assay.nil?
          return render json: { "error" => "No assay result available for sample #{sample.id}" }, status: :not_found
        end

        payload = serialize_material(sample, assay)
        render json: payload.merge("api_version" => API_VERSION)
      rescue ActiveRecord::RecordNotFound
        render json: { "error" => "Material not found" }, status: :not_found
      rescue ArgumentError => e
        render json: { "error" => e.message }, status: :not_found
      end

      private

      def resolve_api_scope!
        if request.authorization.present?
          api_token = ApiToken.authenticate(request.authorization)
          if api_token.nil?
            render json: { "error" => "Invalid or revoked API token" }, status: :unauthorized
            return
          end

          @scoped_materials = api_token.user.user_samples
          return
        end

        session_id = cookies.signed[:session_id]
        if session_id.present? && (session_record = Session.includes(:user).find_by(id: session_id))
          @scoped_materials = session_record.user.user_samples
          return
        end

        if Rails.env.production? || ENV["REQUIRE_API_AUTH"] == "1"
          render json: { "error" => "Bearer API token required" }, status: :unauthorized
        else
          @scoped_materials = UserSample.for_owner(user: nil, guest_token: cookies.signed[:guest_token])
        end
      end

      def serialize_material(sample, assay)
        Exporters::GlazecalcMaterialSerializer.call(assay).merge(
          "links" => {
            "self" => api_v1_material_url(sample),
            "glazecalc_export" => sample_glazecalc_export_url(sample, format: :json),
            "glaze_vault_export" => sample_glaze_vault_export_url(sample, format: :json)
          }
        )
      end

      def latest_preloaded_assay(sample)
        sample.assay_results.max_by { |assay| [ assay.created_at || Time.at(0), assay.id || 0 ] }
      end
    end
  end
end
