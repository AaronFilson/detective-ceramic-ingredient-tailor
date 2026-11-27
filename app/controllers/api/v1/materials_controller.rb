# frozen_string_literal: true

module Api
  module V1
    class MaterialsController < ActionController::API
      API_VERSION = "v1"

      # GET /api/v1/materials
      def index
        samples = UserSample
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
        sample = UserSample.includes(:geologic_unit, :field_observations).find(params[:id])
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
