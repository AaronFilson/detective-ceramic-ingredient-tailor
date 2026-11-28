# frozen_string_literal: true

class SamplesController < ApplicationController
  rate_limit to: 30, within: 1.minute, only: :geologic_lookup, with: -> { head :too_many_requests }

  DEFAULT_LAT = 47.2529
  DEFAULT_LNG = -122.4443
  DEFAULT_ZOOM = 8

  QUICK_LOCATIONS = [
    {
      label: "Tacoma WA",
      subtitle: "Puget Glacial Clay",
      lat: 47.2529,
      lng: -122.4443,
      zoom: 10,
      category: "wild_clay"
    },
    {
      label: "Mt. Rainier Cascades",
      subtitle: "Cascade Andesite",
      lat: 46.7860,
      lng: -121.7350,
      zoom: 10,
      category: "crushed_rock"
    },
    {
      label: "Columbia Gorge Basalt",
      subtitle: "Columbia River Basalt",
      lat: 45.7054,
      lng: -121.5215,
      zoom: 10,
      category: "crushed_rock"
    },
    {
      label: "Spokane Kaolin",
      subtitle: "Latah Kaolin Deposit",
      lat: 47.5580,
      lng: -117.0780,
      zoom: 10,
      category: "wild_clay"
    }
  ].freeze

  def index
    @saved_samples = recent_samples
    @sample = @saved_samples.first || build_default_sample
    load_workbench_context
  end

  def new
    @saved_samples = recent_samples
    setting = current_studio_setting
    @sample = build_default_sample(
      lat: parse_coordinate(params[:lat]) || setting.default_lat.to_f,
      lng: parse_coordinate(params[:lng]) || setting.default_lng.to_f
    )
    load_workbench_context
    render :index
  end

  def show
    @saved_samples = recent_samples
    @sample = scoped_samples
      .with_attached_outcrop_photos
      .includes(
        :geologic_unit,
        :soil_profile,
        :assay_results,
        field_observations: [
          { raw_tile_photo_attachment: :blob },
          { fired_tile_photo_attachment: :blob }
        ]
      )
      .find(params[:id])
    load_workbench_context
    render :index
  end

  def create
    attrs = sample_params
    new_photos = extract_uploaded_photos(attrs.delete(:outcrop_photos))
    @sample = UserSample.new(attrs)
    assign_sample_ownership(@sample)
    exif_pin_note = apply_exif_gps_if_present!(@sample, new_photos)
    assign_geologic_unit_if_needed!(@sample)
    assign_cached_soil_profile_if_needed!(@sample)
    @sample.outcrop_photos.attach(new_photos) if new_photos.any?

    if @sample.save
      enqueue_soil_profile_lookup_if_needed(@sample)
      enqueue_mineral_occurrence_lookup_if_needed(@sample)
      self.class.estimate_sample(@sample)
      notice = "Sample \"#{@sample.title}\" saved and baseline assay calculated."
      notice = "#{notice} #{exif_pin_note}" if exif_pin_note.present?
      redirect_to sample_path(@sample), notice: notice
    else
      @saved_samples = recent_samples
      load_workbench_context
      render :index, status: :unprocessable_entity
    end
  end

  def update
    @sample = scoped_samples.with_attached_outcrop_photos.find(params[:id])
    prev_coords = [ @sample.latitude, @sample.longitude ]
    prev_unit_id = @sample.geologic_unit_id
    attrs = sample_params
    new_photos = extract_uploaded_photos(attrs.delete(:outcrop_photos))
    @sample.assign_attributes(attrs)
    exif_pin_note = apply_exif_gps_if_present!(@sample, new_photos)

    coords_changed = prev_coords != [ @sample.latitude, @sample.longitude ]
    submitted_unit_id = attrs[:geologic_unit_id].presence&.to_i
    explicit_new_unit = submitted_unit_id.present? && submitted_unit_id != prev_unit_id
    assign_geologic_unit_if_needed!(@sample, force: coords_changed && !explicit_new_unit)
    assign_cached_soil_profile_if_needed!(@sample, force: coords_changed)

    saved = false
    UserSample.transaction do
      @sample.outcrop_photos.attach(new_photos) if new_photos.any?
      saved = @sample.save
      raise ActiveRecord::Rollback unless saved
    end

    if saved
      enqueue_soil_profile_lookup_if_needed(@sample)
      enqueue_mineral_occurrence_lookup_if_needed(@sample)
      @assay_result = self.class.estimate_sample(@sample, field_observation: @sample.latest_field_observation)
      notice = "Sample updated and chemical assay recalculated."
      notice = "#{notice} #{exif_pin_note}" if exif_pin_note.present?
      redirect_to sample_path(@sample), notice: notice
    else
      @saved_samples = recent_samples
      load_workbench_context
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    @sample = scoped_samples.find(params[:id])
    title = @sample.title
    @sample.destroy
    redirect_to root_path, notice: "Sample \"#{title}\" deleted."
  end

  def geologic_lookup
    @lat = parse_coordinate(params[:lat])
    @lng = parse_coordinate(params[:lng])
    @sample_id = params[:sample_id].presence
    @lookup_performed = @lat.present? && @lng.present?

    if @lookup_performed
      @geologic_unit = self.class.lookup_geologic_unit(lat: @lat, lng: @lng)
      @soil_profile = self.class.lookup_soil_profile(lat: @lat, lng: @lng)
      @nearby_assay_count = ReferenceAssay.within_radius(@lat, @lng, 50_000).count
    else
      @geologic_unit = nil
      @soil_profile = nil
      @nearby_assay_count = 0
    end

    render :geologic_lookup, layout: !turbo_frame_request?
  end

  def self.lookup_geologic_unit(lat:, lng:)
    return nil if lat.nil? || lng.nil?

    Clients::MacrostratClient.lookup(lat: lat.to_f, lng: lng.to_f)
  rescue StandardError => e
    Rails.logger.warn("[SamplesController] Geologic lookup failed (#{e.class}): #{e.message}")
    nil
  end

  def self.lookup_soil_profile(lat:, lng:)
    return nil if lat.nil? || lng.nil?

    profile = if defined?(Clients::UsdaSsurgoClient)
      Clients::UsdaSsurgoClient.lookup(lat: lat.to_f, lng: lng.to_f)
    else
      SoilProfile.within_radius(lat.to_f, lng.to_f, 250).ordered_by_distance(lat.to_f, lng.to_f).first
    end

    if profile.nil? && defined?(Clients::IsricSoilgridsClient)
      profile = Clients::IsricSoilgridsClient.lookup(lat: lat.to_f, lng: lng.to_f)
    end

    profile
  rescue StandardError => e
    Rails.logger.warn("[SamplesController] Soil profile lookup failed (#{e.class}): #{e.message}")
    nil
  end

  def self.estimate_sample(sample, field_observation: nil)
    Inference::SampleEstimatorService.call(sample, field_observation: field_observation)
  end

  private

  def recent_samples
    scoped_samples
      .with_attached_outcrop_photos
      .includes(:geologic_unit, :soil_profile, :assay_results)
      .order(updated_at: :desc, id: :desc)
      .limit(30)
  end

  def build_default_sample(lat: nil, lng: nil)
    setting = current_studio_setting
    UserSample.new(
      material_category: setting.default_material_category,
      latitude: lat || setting.default_lat.to_f,
      longitude: lng || setting.default_lng.to_f
    )
  end

  def load_workbench_context
    @studio_setting = current_studio_setting
    @show_onboarding_wizard = @studio_setting.onboarding_needed? && params[:skip_wizard].blank?
    @map_lat = @sample.latitude || @studio_setting.default_lat.to_f
    @map_lng = @sample.longitude || @studio_setting.default_lng.to_f
    @map_zoom = @sample.persisted? ? 10 : @studio_setting.default_zoom
    @geologic_unit = @sample.geologic_unit
    @soil_profile = @sample.soil_profile
    @assay_result = @sample.persisted? ? @sample.latest_assay_result : nil
    @heuristic_assay = @sample.persisted? ? @sample.latest_heuristic_assay_result : nil
    @verified_lab_assay = @sample.persisted? ? @sample.latest_verified_lab_assay : nil
    @field_observation = if @sample.persisted?
      latest = @sample.latest_field_observation
      @sample.field_observations.build(
        vinegar_fizz: latest&.vinegar_fizz || :none,
        slaking_behavior: latest&.slaking_behavior,
        plasticity: latest&.plasticity,
        raw_color: latest&.raw_color,
        fired_cone: latest&.fired_cone.presence || @studio_setting.default_fired_cone,
        fired_color: latest&.fired_color,
        melt_state: latest&.melt_state,
        shrinkage_percent: latest&.shrinkage_percent,
        water_of_plasticity: latest&.water_of_plasticity,
        drying_shrinkage_percent: latest&.drying_shrinkage_percent,
        firing_shrinkage_percent: latest&.firing_shrinkage_percent,
        boiling_water_absorption_percent: latest&.boiling_water_absorption_percent
      )
    else
      FieldObservation.new(fired_cone: @studio_setting.default_fired_cone)
    end
    @quick_locations = QUICK_LOCATIONS
    @reference_assays_payload = build_reference_assays_payload(@map_lat, @map_lng)
    @mineral_occurrences_payload = build_mineral_occurrences_payload(@map_lat, @map_lng)
    @nearby_mineral_occurrences = MineralOccurrence
      .where.not(location: nil)
      .within_radius(@map_lat, @map_lng, 100_000)
      .with_distance_from(@map_lat, @map_lng)
      .ordered_by_distance(@map_lat, @map_lng)
      .limit(8)
    @nearby_xrd_assays = ReferenceAssay
      .where("xrd_mineralogy <> '{}'::jsonb")
      .within_radius(@map_lat, @map_lng, 250_000)
      .ordered_by_distance(@map_lat, @map_lng)
      .limit(5)
  end

  def build_reference_assays_payload(lat, lng)
    ReferenceAssay
      .where.not(location: nil)
      .ordered_by_distance(lat, lng)
      .limit(60)
      .map do |assay|
        {
          id: assay.id,
          external_id: assay.external_id,
          source: assay.source,
          rock_type: assay.rock_type,
          lat: assay.latitude&.round(5),
          lng: assay.longitude&.round(5),
          locality: assay.raw_metadata["locality"] || assay.raw_metadata["LOCALITY"],
          formation: assay.raw_metadata["formation"] || assay.raw_metadata["FORMATION"],
          oxides: {
            SiO2: assay.oxide_value("SiO2")&.round(2),
            Al2O3: assay.oxide_value("Al2O3")&.round(2),
            Fe2O3: assay.oxide_value("Fe2O3")&.round(2),
            CaO: assay.oxide_value("CaO")&.round(2),
            LOI: assay.oxide_value("LOI")&.round(2)
          }
        }
      end
  end

  def build_mineral_occurrences_payload(lat, lng)
    MineralOccurrence
      .where.not(location: nil)
      .ordered_by_distance(lat, lng)
      .limit(40)
      .map do |occ|
        {
          id: occ.id,
          external_id: occ.external_id,
          name: occ.name,
          source: occ.source,
          deposit_type: occ.deposit_type,
          commodities: Array(occ.commodities),
          minerals: Array(occ.minerals),
          ceramic_highlights: occ.ceramic_highlights,
          lat: occ.latitude&.round(5),
          lng: occ.longitude&.round(5)
        }
      end
  end

  def assign_geologic_unit_if_needed!(sample, force: false)
    return if sample.latitude.nil? || sample.longitude.nil?
    return if sample.geologic_unit_id.present? && !force

    unit = self.class.lookup_geologic_unit(lat: sample.latitude, lng: sample.longitude)
    if force
      sample.geologic_unit = unit
    elsif unit.present?
      sample.geologic_unit = unit
    end
  end

  def assign_cached_soil_profile_if_needed!(sample, force: false)
    sample.soil_profile = nil if force
    return if sample.latitude.nil? || sample.longitude.nil?
    return if sample.soil_profile_id.present?

    cached = SoilProfile.within_radius(sample.latitude, sample.longitude, 250)
      .ordered_by_distance(sample.latitude, sample.longitude)
      .first
    sample.soil_profile = cached if cached.present?
  rescue StandardError => e
    Rails.logger.warn("[SamplesController] Cached soil profile lookup failed (#{e.class}): #{e.message}")
  end

  def enqueue_soil_profile_lookup_if_needed(sample)
    return unless defined?(SoilProfileLookupJob)
    return unless sample.soil_profile_id.nil?
    return if sample.latitude.nil? || sample.longitude.nil?

    SoilProfileLookupJob.perform_later(sample.id)
  rescue StandardError => e
    Rails.logger.warn("[SamplesController] Soil profile lookup job enqueue failed (#{e.class}): #{e.message}")
  end

  def enqueue_mineral_occurrence_lookup_if_needed(sample)
    return unless defined?(MineralOccurrenceLookupJob)
    return if sample.latitude.nil? || sample.longitude.nil?
    return if MineralOccurrence.by_source("usgs_mrds").within_radius(sample.latitude, sample.longitude, 50_000).exists?

    MineralOccurrenceLookupJob.perform_later(sample.latitude, sample.longitude)
  rescue StandardError => e
    Rails.logger.warn("[SamplesController] Mineral occurrence lookup job enqueue failed (#{e.class}): #{e.message}")
  end

  def parse_coordinate(value)
    return nil if value.blank?

    num = Float(value)
    return nil if num.nan? || num.infinite?

    num
  rescue ArgumentError, TypeError
    nil
  end

  def extract_uploaded_photos(raw_photos)
    Array(raw_photos).reject(&:blank?)
  end

  def apply_exif_gps_if_present!(sample, uploaded_photos)
    return nil if uploaded_photos.empty?

    should_auto_pin = params[:auto_pin_from_photo].to_s == "1" ||
      (sample.latitude.nil? && sample.longitude.nil?)
    return nil unless should_auto_pin

    coords = uploaded_photos.lazy.filter_map { |photo| Media::ExifGpsExtractor.extract(photo) }.first
    return nil unless coords

    sample.latitude = coords[:latitude]
    sample.longitude = coords[:longitude]
    format(
      "Pinned coordinates (%.4f, %.4f) automatically from outcrop photo EXIF GPS.",
      coords[:latitude],
      coords[:longitude]
    )
  end

  def sample_params
    params.require(:user_sample).permit(
      :title,
      :material_category,
      :latitude,
      :longitude,
      :geologic_unit_id,
      :notes,
      outcrop_photos: []
    )
  end
end
