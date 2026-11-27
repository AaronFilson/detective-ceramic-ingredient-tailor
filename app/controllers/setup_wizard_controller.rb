# frozen_string_literal: true

class SetupWizardController < ApplicationController
  def show
    @studio_setting = current_studio_setting
    @initial_step = parse_step(params[:step])
  end

  def update
    @studio_setting = current_studio_setting
    @studio_setting.assign_attributes(setup_params)
    @studio_setting.onboarding_completed_at = Time.current
    @studio_setting.onboarding_skipped_at = nil

    if @studio_setting.save
      starter = create_starter_sample_if_requested(@studio_setting)
      if starter.present?
        redirect_to sample_path(starter),
          notice: "Welcome to DCI Tailor! Studio preferences saved and starter sample \"#{starter.title}\" created."
      else
        redirect_to root_path,
          notice: "Studio preferences saved for DCI Tailor (#{@studio_setting.home_region_label}, Cone #{@studio_setting.default_fired_cone})."
      end
    else
      @initial_step = 2
      render :show, status: :unprocessable_entity
    end
  end

  def skip
    current_studio_setting.skip_onboarding!

    respond_to do |format|
      format.turbo_stream { render turbo_stream: turbo_stream.remove("setup_wizard_modal") }
      format.html { redirect_to root_path, notice: "Skipped setup for now — you can open the Setup Wizard anytime from the top bar." }
    end
  end

  def reset
    current_studio_setting.reset_onboarding!
    redirect_to setup_path, notice: "Setup wizard reset. Walk through your DCI Tailor studio preferences below."
  end

  private

  def parse_step(raw)
    step = raw.to_i
    step.between?(1, 4) ? step : 1
  end

  def setup_params
    params.require(:studio_setting).permit(
      :studio_name,
      :home_region_label,
      :default_lat,
      :default_lng,
      :default_zoom,
      :default_material_category,
      :default_fired_cone,
      :default_blend_surface,
      :show_macrostrat_layer,
      :show_reference_assays_layer,
      :show_mineral_occurrences_layer,
      :has_pxrf_workflow,
      :preferred_export_target,
      :glazecalc_base_url
    )
  end

  def create_starter_sample_if_requested(setting)
    return nil unless ActiveModel::Type::Boolean.new.cast(params[:create_starter_sample])

    category_label = setting.default_material_category.to_s.tr("_", " ").titleize
    sample = UserSample.new(
      title: "#{setting.home_region_label} Starter #{category_label}",
      material_category: setting.default_material_category,
      latitude: setting.default_lat.to_f,
      longitude: setting.default_lng.to_f,
      notes: "Starter sample created during DCI Tailor first-time setup."
    )

    cached_unit = GeologicUnit
      .where("boundary IS NOT NULL AND ST_Covers(boundary, ST_SetSRID(ST_MakePoint(?, ?), 4326))", sample.longitude, sample.latitude)
      .order(Arel.sql("ST_Area(boundary::geography) ASC"))
      .first
    sample.geologic_unit = cached_unit if cached_unit.present?

    cached_soil = SoilProfile.within_radius(sample.latitude, sample.longitude, 500)
      .ordered_by_distance(sample.latitude, sample.longitude)
      .first
    sample.soil_profile = cached_soil if cached_soil.present?

    if sample.save
      SamplesController.estimate_sample(sample)
      sample
    end
  rescue StandardError => e
    Rails.logger.warn("[SetupWizardController] Starter sample creation skipped (#{e.class}): #{e.message}")
    nil
  end
end
