# frozen_string_literal: true

class SamplesController < ApplicationController
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
    @sample = build_default_sample(
      lat: parse_coordinate(params[:lat]) || DEFAULT_LAT,
      lng: parse_coordinate(params[:lng]) || DEFAULT_LNG
    )
    load_workbench_context
    render :index
  end

  def show
    @saved_samples = recent_samples
    @sample = UserSample.includes(:geologic_unit, :field_observations, :assay_results).find(params[:id])
    load_workbench_context
    render :index
  end

  def create
    @sample = UserSample.new(sample_params)
    assign_geologic_unit_if_needed!(@sample)

    if @sample.save
      self.class.estimate_sample(@sample)
      redirect_to sample_path(@sample), notice: "Sample \"#{@sample.title}\" saved and baseline assay calculated."
    else
      @saved_samples = recent_samples
      load_workbench_context
      render :index, status: :unprocessable_entity
    end
  end

  def update
    @sample = UserSample.find(params[:id])
    prev_coords = [ @sample.latitude, @sample.longitude ]
    @sample.assign_attributes(sample_params)

    coords_changed = prev_coords != [ @sample.latitude, @sample.longitude ]
    explicit_unit = sample_params[:geologic_unit_id].present?
    assign_geologic_unit_if_needed!(@sample, force: coords_changed && !explicit_unit)

    if @sample.save
      @assay_result = self.class.estimate_sample(@sample, field_observation: @sample.latest_field_observation)
      redirect_to sample_path(@sample), notice: "Sample updated and chemical assay recalculated."
    else
      @saved_samples = recent_samples
      load_workbench_context
      render :index, status: :unprocessable_entity
    end
  end

  def destroy
    @sample = UserSample.find(params[:id])
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
      @nearby_assay_count = ReferenceAssay.within_radius(@lat, @lng, 50_000).count
    else
      @geologic_unit = nil
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

  def self.estimate_sample(sample, field_observation: nil)
    Inference::SampleEstimatorService.call(sample, field_observation: field_observation)
  end

  private

  def recent_samples
    UserSample.includes(:geologic_unit, :assay_results).order(updated_at: :desc, id: :desc).limit(30)
  end

  def build_default_sample(lat: DEFAULT_LAT, lng: DEFAULT_LNG)
    UserSample.new(
      material_category: :wild_clay,
      latitude: lat,
      longitude: lng
    )
  end

  def load_workbench_context
    @map_lat = @sample.latitude || DEFAULT_LAT
    @map_lng = @sample.longitude || DEFAULT_LNG
    @map_zoom = @sample.persisted? ? 10 : DEFAULT_ZOOM
    @geologic_unit = @sample.geologic_unit
    @assay_result = @sample.persisted? ? @sample.latest_assay_result : nil
    @field_observation = if @sample.persisted?
      latest = @sample.latest_field_observation
      @sample.field_observations.build(
        vinegar_fizz: latest&.vinegar_fizz || :none,
        slaking_behavior: latest&.slaking_behavior,
        plasticity: latest&.plasticity,
        raw_color: latest&.raw_color,
        fired_cone: latest&.fired_cone,
        fired_color: latest&.fired_color,
        melt_state: latest&.melt_state,
        shrinkage_percent: latest&.shrinkage_percent
      )
    else
      FieldObservation.new
    end
    @quick_locations = QUICK_LOCATIONS
    @reference_assays_payload = build_reference_assays_payload(@map_lat, @map_lng)
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

  def assign_geologic_unit_if_needed!(sample, force: false)
    return if sample.latitude.nil? || sample.longitude.nil?
    return if sample.geologic_unit_id.present? && !force

    unit = self.class.lookup_geologic_unit(lat: sample.latitude, lng: sample.longitude)
    sample.geologic_unit = unit if unit.present?
  end

  def parse_coordinate(value)
    return nil if value.blank?

    num = Float(value)
    return nil if num.nan? || num.infinite?

    num
  rescue ArgumentError, TypeError
    nil
  end

  def sample_params
    params.require(:user_sample).permit(
      :title,
      :material_category,
      :latitude,
      :longitude,
      :geologic_unit_id,
      :notes
    )
  end
end
