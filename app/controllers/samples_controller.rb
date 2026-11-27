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

  # Molecular weights & fallback profiles used ONLY before Agents 2 & 3 merge.
  MOLECULAR_WEIGHTS = {
    "SiO2"  => 60.08,
    "Al2O3" => 101.96,
    "Fe2O3" => 159.69,
    "CaO"   => 56.08,
    "MgO"   => 40.30,
    "Na2O"  => 61.98,
    "K2O"   => 94.20,
    "TiO2"  => 79.87,
    "P2O5"  => 141.94,
    "MnO"   => 70.94
  }.freeze

  FLUX_OXIDES = %w[CaO MgO Na2O K2O].freeze
  INTERMEDIATE_OXIDES = %w[Al2O3 Fe2O3 MnO].freeze
  GLASS_FORMER_OXIDES = %w[SiO2 TiO2 P2O5].freeze

  CATEGORY_ROCK_TYPES = {
    "wild_clay"    => %w[glacial_clay alluvial_clay marine_clay kaolin_clay shale siltstone clay mudstone],
    "crushed_rock" => %w[basalt andesite granite granodiorite rhyolite gabbro limestone],
    "wood_ash"     => %w[limestone],
    "other"        => []
  }.freeze

  CATEGORY_DEFAULTS = {
    "wild_clay" => {
      "SiO2" => 59.0, "Al2O3" => 17.5, "Fe2O3" => 6.2, "CaO" => 2.8, "MgO" => 2.3,
      "Na2O" => 2.2, "K2O" => 2.4, "TiO2" => 0.85, "P2O5" => 0.18, "MnO" => 0.11, "LOI" => 6.46
    },
    "crushed_rock" => {
      "SiO2" => 56.5, "Al2O3" => 15.8, "Fe2O3" => 8.8, "CaO" => 7.2, "MgO" => 4.2,
      "Na2O" => 3.4, "K2O" => 1.8, "TiO2" => 1.25, "P2O5" => 0.25, "MnO" => 0.15, "LOI" => 0.65
    },
    "wood_ash" => {
      "SiO2" => 11.5, "Al2O3" => 2.4, "Fe2O3" => 1.5, "CaO" => 36.5, "MgO" => 5.5,
      "Na2O" => 1.2, "K2O" => 8.8, "TiO2" => 0.2, "P2O5" => 4.4, "MnO" => 1.0, "LOI" => 27.0
    },
    "other" => {
      "SiO2" => 60.0, "Al2O3" => 16.0, "Fe2O3" => 5.5, "CaO" => 4.0, "MgO" => 2.5,
      "Na2O" => 2.5, "K2O" => 2.5, "TiO2" => 0.8, "P2O5" => 0.2, "MnO" => 0.1, "LOI" => 5.9
    }
  }.freeze

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

  # Interop entry point for Macrostrat lookup: uses Agent 2's Clients::MacrostratClient
  # automatically when merged, falling back to local PostGIS boundary cache otherwise.
  def self.lookup_geologic_unit(lat:, lng:)
    return nil if lat.nil? || lng.nil?

    if defined?(Clients::MacrostratClient)
      Clients::MacrostratClient.lookup(lat: lat.to_f, lng: lng.to_f)
    else
      GeologicUnit.where(
        "boundary IS NOT NULL AND ST_Covers(boundary, ST_SetSRID(ST_MakePoint(?, ?), 4326))",
        lng.to_f,
        lat.to_f
      ).first
    end
  rescue StandardError => e
    Rails.logger.warn("[SamplesController] Geologic lookup failed (#{e.class}): #{e.message}")
    nil
  end

  # Interop entry point for chemical inference: uses Agent 3's Inference::SampleEstimatorService
  # automatically when merged, falling back to a self-contained estimator otherwise.
  def self.estimate_sample(sample, field_observation: nil)
    if defined?(Inference::SampleEstimatorService)
      Inference::SampleEstimatorService.call(sample, field_observation: field_observation)
    else
      fallback_estimate_sample(sample, field_observation: field_observation)
    end
  end

  class << self
    private

    def fallback_estimate_sample(sample, field_observation: nil)
      obs = field_observation || sample.latest_field_observation
      baseline = fallback_baseline_for(sample)
      oxides = baseline[:oxides].dup
      ranges = baseline[:oxide_ranges].deep_dup
      reasoning = baseline[:reasoning_log].dup
      confidence = baseline[:confidence_score]

      if obs.present?
        confidence = apply_fallback_observation!(oxides, ranges, reasoning, obs, confidence)
      end

      normalized_oxides = normalize_to_exact_100(oxides)
      sync_ranges_with_oxides!(ranges, normalized_oxides)
      umf = fallback_calculate_umf(normalized_oxides)

      assay = sample.assay_results.spatial_heuristic_estimate.order(created_at: :desc, id: :desc).first ||
              sample.assay_results.build(source_type: :spatial_heuristic_estimate)

      assay.assign_attributes(
        oxides: normalized_oxides,
        oxide_ranges: ranges,
        umf_formula: umf,
        confidence_score: confidence.clamp(0.05, 0.99).round(3),
        reasoning_log: reasoning
      )
      assay.save!
      assay
    end

    def fallback_baseline_for(sample)
      lat = sample.latitude
      lng = sample.longitude
      category = sample.material_category.to_s
      rock_types = CATEGORY_ROCK_TYPES.fetch(category, [])

      matched = []
      reason = nil
      confidence = 0.35

      if lat.present? && lng.present?
        scoped = rock_types.any? ? ReferenceAssay.where(rock_type: rock_types) : ReferenceAssay.all

        tier1 = scoped.within_radius(lat, lng, 15_000).to_a
        tier2 = tier1.size >= 5 ? [] : scoped.within_radius(lat, lng, 50_000).to_a
        tier3 = (tier1.size >= 5 || tier2.size >= 5) ? [] : ReferenceAssay.within_radius(lat, lng, 50_000).to_a

        if tier1.size >= 5
          matched = tier1
          confidence = 0.78
          reason = "Spatial baseline: #{matched.size} nearby #{category.humanize.downcase} assays within 15 km."
        elsif tier2.size >= 5
          matched = tier2
          confidence = 0.68
          reason = "Spatial baseline: expanded to #{matched.size} regional #{category.humanize.downcase} assays within 50 km."
        elsif tier3.size >= 5
          matched = tier3
          confidence = 0.56
          reason = "Spatial baseline: used #{matched.size} unfiltered reference assays within 50 km."
        elsif rock_types.any?
          matched = scoped.limit(25).to_a
          if matched.any?
            confidence = 0.45
            reason = "Spatial fallback: used #{matched.size} global #{category.humanize.downcase} reference assays."
          end
        end
      end

      if matched.any?
        ranges = compute_ranges(matched)
        medians = CeramicOxides::KEYS.index_with { |k| ranges[k]["median"] }
        oxides = normalize_to_exact_100(medians)
        {
          oxides: oxides,
          oxide_ranges: ranges,
          confidence_score: confidence,
          reasoning_log: [ reason ]
        }
      else
        defaults = CATEGORY_DEFAULTS.fetch(category, CATEGORY_DEFAULTS["other"])
        oxides = normalize_to_exact_100(defaults)
        ranges = CeramicOxides::KEYS.index_with do |k|
          med = oxides[k]
          spread = [ (med * 0.25).round(2), 0.2 ].max
          min_v = [ (med - spread).round(2), 0.0 ].max
          max_v = (med + spread).round(2)
          {
            "min" => min_v,
            "q1" => [ (med - spread * 0.5).round(2), 0.0 ].max,
            "median" => med,
            "q3" => (med + spread * 0.5).round(2),
            "max" => max_v,
            "iqr" => (spread).round(2)
          }
        end
        {
          oxides: oxides,
          oxide_ranges: ranges,
          confidence_score: 0.30,
          reasoning_log: [ "Default #{category.humanize.downcase} compositional baseline applied (no local reference assays within 50 km)." ]
        }
      end
    end

    def compute_ranges(assays)
      CeramicOxides::KEYS.index_with do |key|
        vals = assays.map { |a| a.oxide_value(key).to_f }.sort
        min_v = vals.first.round(2)
        q1_v  = percentile(vals, 0.25).round(2)
        med_v = percentile(vals, 0.50).round(2)
        q3_v  = percentile(vals, 0.75).round(2)
        max_v = vals.last.round(2)
        {
          "min" => min_v,
          "q1" => q1_v,
          "median" => med_v,
          "q3" => q3_v,
          "max" => max_v,
          "iqr" => (q3_v - q1_v).round(2)
        }
      end
    end

    def percentile(sorted, p)
      return 0.0 if sorted.empty?
      return sorted.first if sorted.size == 1

      rank = p * (sorted.size - 1)
      lower = rank.floor
      upper = rank.ceil
      weight = rank - lower
      sorted[lower] + weight * (sorted[upper] - sorted[lower])
    end

    def apply_fallback_observation!(oxides, ranges, reasoning, obs, confidence)
      boost = 0.0

      if obs.vinegar_fizz_vigorous?
        q3 = ranges.dig("CaO", "q3").to_f
        med = oxides["CaO"].to_f
        delta_cao = [ q3 - med, 5.0 ].max.clamp(3.0, 8.0).round(2)
        delta_loi = (delta_cao * 0.785).round(2)
        oxides["CaO"] = (oxides["CaO"].to_f + delta_cao).round(2)
        oxides["LOI"] = (oxides["LOI"].to_f + delta_loi).round(2)
        reasoning << "Vinegar fizz (vigorous): strong CaCO3 carbonate reaction — shifted CaO +#{delta_cao}% and LOI +#{delta_loi}%."
        boost += 0.08
      elsif obs.vinegar_fizz_slight?
        delta_cao = 1.8
        delta_loi = (delta_cao * 0.785).round(2)
        oxides["CaO"] = (oxides["CaO"].to_f + delta_cao).round(2)
        oxides["LOI"] = (oxides["LOI"].to_f + delta_loi).round(2)
        reasoning << "Vinegar fizz (slight): minor carbonate presence — shifted CaO +#{delta_cao}% and LOI +#{delta_loi}%."
        boost += 0.04
      end

      color_source = obs.fired_color.presence || obs.raw_color.presence
      if color_source.present?
        color_down = color_source.downcase
        if color_down.match?(/buff|white|ivory|cream|pale|porcelain/)
          if oxides["Fe2O3"].to_f > 1.4
            oxides["Fe2O3"] = 1.2
          end
          reasoning << "Color cue (#{color_source}): low-iron body — capped Fe2O3 below 1.5%."
          boost += 0.05
        elsif color_down.match?(/red|terracotta|brown|rust|mahogany|ochre|dark|chocolate|iron/)
          target_fe = [ oxides["Fe2O3"].to_f, 5.5 ].max.clamp(4.0, 9.0).round(2)
          oxides["Fe2O3"] = target_fe
          reasoning << "Color cue (#{color_source}): iron-bearing oxide signature — elevated Fe2O3 into 4.0–9.0% band (#{target_fe}%)."
          boost += 0.05
        end
      end

      cone_num = parse_cone_number(obs.fired_cone)
      if obs.melt_state.present?
        if cone_num && cone_num <= 6 && (obs.melted_fluid? || obs.bloated?)
          oxides["Na2O"] = (oxides["Na2O"].to_f + 1.4).round(2)
          oxides["K2O"] = (oxides["K2O"].to_f + 1.6).round(2)
          oxides["CaO"] = (oxides["CaO"].to_f + 1.5).round(2) if obs.melted_fluid?
          oxides["Fe2O3"] = (oxides["Fe2O3"].to_f + 1.2).round(2) if obs.bloated?
          reasoning << "Fired test (Cone #{obs.fired_cone}, #{obs.melt_state.humanize.downcase}): low/mid-temp fluxing — boosted alkali/flux oxides."
          boost += 0.06
        elsif cone_num && cone_num >= 8 && obs.refractory_chalky?
          oxides["Al2O3"] = (oxides["Al2O3"].to_f + 5.0).round(2)
          oxides["SiO2"] = (oxides["SiO2"].to_f + 2.5).round(2)
          oxides["Na2O"] = [ oxides["Na2O"].to_f - 0.8, 0.2 ].max.round(2)
          oxides["K2O"] = [ oxides["K2O"].to_f - 0.8, 0.2 ].max.round(2)
          reasoning << "Fired test (Cone #{obs.fired_cone}, refractory/chalky): high refractoriness — boosted Al2O3 & SiO2, dampened fluxes."
          boost += 0.06
        elsif obs.vitrified_tight?
          reasoning << "Fired test (#{obs.fired_cone.present? ? "Cone #{obs.fired_cone}" : "test tile"}): vitrified tight stoneware maturation confirmed."
          boost += 0.04
        end
      end

      if obs.high_plastic?
        oxides["Al2O3"] = (oxides["Al2O3"].to_f + 2.5).round(2)
        oxides["LOI"] = (oxides["LOI"].to_f + 2.0).round(2)
        oxides["SiO2"] = [ oxides["SiO2"].to_f - 2.0, 10.0 ].max.round(2)
        reasoning << "Plasticity (high): clay-mineral rich profile — increased Al2O3 & LOI, trimmed free SiO2."
        boost += 0.04
      elsif obs.short_non_plastic?
        oxides["SiO2"] = (oxides["SiO2"].to_f + 3.0).round(2)
        oxides["K2O"] = (oxides["K2O"].to_f + 1.0).round(2)
        oxides["Na2O"] = (oxides["Na2O"].to_f + 0.8).round(2)
        oxides["LOI"] = [ oxides["LOI"].to_f - 2.5, 0.3 ].max.round(2)
        reasoning << "Plasticity (short/non-plastic): feldspathic/siliceous profile — raised SiO2 & alkalis, lowered LOI."
        boost += 0.04
      end

      if obs.fast_disintegration?
        reasoning << "Slaking (fast disintegration): unconsolidated fine clay/silt structure confirmed."
        boost += 0.02
      elsif obs.no_slake?
        oxides["LOI"] = [ oxides["LOI"].to_f - 0.8, 0.2 ].max.round(2)
        reasoning << "Slaking (no slake): indurated shale or rock matrix — slight LOI reduction."
        boost += 0.02
      end

      confidence + boost
    end

    def parse_cone_number(cone_str)
      return nil if cone_str.blank?

      str = cone_str.to_s.strip
      return -str[1..].to_i if str.start_with?("0") && str.match?(/\A0\d+\z/)
      return str.to_i if str.match?(/\A\d+\z/)

      nil
    end

    def normalize_to_exact_100(raw_oxides)
      normalized = CeramicOxides.normalize(raw_oxides, precision: 2) ||
                   CeramicOxides::KEYS.index_with { 0.0 }
      diff = (100.0 - normalized.values.sum).round(2)
      if diff != 0.0
        largest_key = normalized.max_by { |_, v| v }&.first
        normalized[largest_key] = (normalized[largest_key] + diff).round(2) if largest_key
      end
      normalized
    end

    def sync_ranges_with_oxides!(ranges, oxides)
      CeramicOxides::KEYS.each do |key|
        val = oxides[key].to_f
        entry = (ranges[key] ||= {})
        min_v = [ entry.fetch("min", val).to_f, val ].min.round(2)
        max_v = [ entry.fetch("max", val).to_f, val ].max.round(2)
        q1_v  = entry.fetch("q1", (min_v + val) / 2.0).to_f.clamp(min_v, val).round(2)
        q3_v  = entry.fetch("q3", (val + max_v) / 2.0).to_f.clamp(val, max_v).round(2)
        ranges[key] = {
          "min" => min_v,
          "q1" => q1_v,
          "median" => val.round(2),
          "q3" => q3_v,
          "max" => max_v,
          "iqr" => (q3_v - q1_v).round(2)
        }
      end
    end

    def fallback_calculate_umf(oxides)
      moles_per_100g = {}
      MOLECULAR_WEIGHTS.each do |oxide, mw|
        wt = oxides[oxide].to_f
        moles_per_100g[oxide] = wt.positive? ? (wt / mw) : 0.0
      end

      flux_raw_sum = FLUX_OXIDES.sum { |ox| moles_per_100g[ox] }
      loi = oxides["LOI"].to_f

      if flux_raw_sum.positive?
        unity = moles_per_100g.transform_values { |m| (m / flux_raw_sum).round(4) }
        flux_total = FLUX_OXIDES.sum { |ox| unity[ox] }.round(4)
        eq_wt = (100.0 / flux_raw_sum).round(2)
        fw = (eq_wt * (1.0 - loi / 100.0)).round(2)
      else
        unity = moles_per_100g.transform_values { |m| m.round(4) }
        flux_total = 0.0
        eq_wt = 100.0
        fw = (100.0 * (1.0 - loi / 100.0)).round(2)
      end

      al_val = unity["Al2O3"].to_f
      si_al = al_val.positive? ? (unity["SiO2"].to_f / al_val).round(3) : nil

      {
        "fluxes" => FLUX_OXIDES.index_with { |ox| unity[ox] },
        "intermediates" => INTERMEDIATE_OXIDES.index_with { |ox| unity[ox] },
        "glass_formers" => GLASS_FORMER_OXIDES.index_with { |ox| unity[ox] },
        "oxides" => unity,
        "flux_total" => flux_total,
        "r2o_total" => (unity["Na2O"].to_f + unity["K2O"].to_f).round(4),
        "ro_total" => (unity["CaO"].to_f + unity["MgO"].to_f).round(4),
        "si_al_ratio" => si_al,
        "equivalent_weight" => eq_wt,
        "formula_weight" => fw
      }
    end
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
