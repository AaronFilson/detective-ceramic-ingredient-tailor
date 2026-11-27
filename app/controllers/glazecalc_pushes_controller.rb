# frozen_string_literal: true

class GlazecalcPushesController < ApplicationController
  before_action :set_sample

  def create
    api_token = extract_param(:api_token).to_s
    base_url = extract_param(:base_url).presence || Clients::GlazecalcPushClient::DEFAULT_BASE_URL

    @push_result = Clients::GlazecalcPushClient.call(
      @sample,
      api_token: api_token,
      base_url: base_url
    )

    respond_to do |format|
      format.turbo_stream do
        render :create, status: @push_result.success? ? :ok : :unprocessable_content
      end
      format.html do
        if @push_result.success?
          redirect_to sample_path(@sample), notice: @push_result.message
        else
          redirect_to sample_path(@sample), alert: @push_result.message
        end
      end
    end
  end

  private

  def set_sample
    @sample = UserSample.includes(:geologic_unit, :field_observations, :assay_results).find(params[:sample_id])
  end

  def extract_param(key)
    params[key].presence || params.dig(:glazecalc_push, key).presence
  end
end
