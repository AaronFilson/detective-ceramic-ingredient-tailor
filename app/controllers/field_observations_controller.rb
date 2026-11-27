# frozen_string_literal: true

class FieldObservationsController < ApplicationController
  before_action :set_sample

  def create
    @field_observation = @sample.field_observations.build(field_observation_params)

    if @field_observation.save
      @assay_result = SamplesController.estimate_sample(@sample, field_observation: @field_observation)

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to sample_path(@sample), notice: "Field observation logged and chemical estimate updated." }
      end
    else
      @assay_result = @sample.latest_assay_result

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "field_observation_form",
            partial: "field_observations/form",
            locals: { sample: @sample, field_observation: @field_observation }
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to sample_path(@sample), alert: @field_observation.errors.full_messages.to_sentence
        end
      end
    end
  end

  def update
    @field_observation = @sample.field_observations.find(params[:id])

    if @field_observation.update(field_observation_params)
      @assay_result = SamplesController.estimate_sample(@sample, field_observation: @field_observation)

      respond_to do |format|
        format.turbo_stream { render :create }
        format.html { redirect_to sample_path(@sample), notice: "Field observation updated and chemical estimate recalculated." }
      end
    else
      @assay_result = @sample.latest_assay_result

      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(
            "field_observation_form",
            partial: "field_observations/form",
            locals: { sample: @sample, field_observation: @field_observation }
          ), status: :unprocessable_entity
        end
        format.html do
          redirect_to sample_path(@sample), alert: @field_observation.errors.full_messages.to_sentence
        end
      end
    end
  end

  private

  def set_sample
    @sample = UserSample.find(params[:sample_id])
  end

  def field_observation_params
    permitted = params.require(:field_observation).permit(
      :vinegar_fizz,
      :slaking_behavior,
      :plasticity,
      :raw_color,
      :fired_cone,
      :fired_color,
      :melt_state,
      :shrinkage_percent,
      :water_of_plasticity,
      :drying_shrinkage_percent,
      :firing_shrinkage_percent,
      :boiling_water_absorption_percent
    )
    # Normalize blank optional enum strings to nil so Rails enum validation accepts optional blank choices
    %i[slaking_behavior plasticity melt_state].each do |enum_attr|
      permitted[enum_attr] = nil if permitted[enum_attr].blank?
    end
    permitted[:vinegar_fizz] = :none if permitted[:vinegar_fizz].blank?
    permitted
  end
end
