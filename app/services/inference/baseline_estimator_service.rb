# frozen_string_literal: true

module Inference
  class BaselineEstimatorService
    Result = Struct.new(
      :oxide_ranges,
      :oxides,
      :confidence_score,
      :sample_count,
      :search_radius_meters,
      :strategy,
      :reasoning_log,
      :matched_assay_ids,
      keyword_init: true
    )

    LOCAL_RADIUS_METERS = 15_000
    REGIONAL_RADIUS_METERS = 50_000
    MIN_SPATIAL_MATCHES = 5
    RANGE_PRECISION = 3
    OXIDE_PRECISION = 2

    CATEGORY_ROCK_TYPES = {
      "wild_clay" => %w[
        glacial_clay alluvial_clay marine_clay kaolin_clay
        shale siltstone clay mudstone claystone ball_clay
        fire_clay stoneware_clay earthenware_clay loess marl
      ].freeze,
      "crushed_rock" => %w[
        basalt andesite granite granodiorite rhyolite gabbro limestone
        diorite dacite diabase dolerite dolomite marble gneiss schist
        slate quartzite sandstone feldspar pegmatite syenite tuff
        pumice obsidian scoria perlite
      ].freeze,
      "wood_ash" => %w[
        wood_ash ash plant_ash
      ].freeze,
      "other" => [].freeze
    }.freeze

    LITHOLOGY_KEYWORD_RULES = [
      [/\b(?:kaolin|china\s+clay|residual\s+clay|bauxite|laterite)\b/i, %w[kaolin_clay]],
      [/\b(?:glacial|till|drift|moraine|outwash|glaciolacustrine|lacustrine)\b/i, %w[glacial_clay marine_clay alluvial_clay clay]],
      [/\b(?:glaciomarine|marine|estuar\w*|tidal)\b/i, %w[marine_clay glacial_clay clay shale]],
      [/\b(?:alluvi\w*|fluvial|river|floodplain|delta\w*|terrace)\b/i, %w[alluvial_clay glacial_clay clay siltstone]],
      [/\b(?:siltstone|silt)\b/i, %w[siltstone shale alluvial_clay]],
      [/\b(?:shale|mudstone|claystone|argill\w*)\b/i, %w[shale siltstone mudstone clay]],
      [/\b(?:clay|mud|loam|loess|marl)\b/i, %w[glacial_clay alluvial_clay marine_clay kaolin_clay clay mudstone shale]],
      [/\b(?:basalt\w*|mafic|diabase|dolerite|scoria|trap)\b/i, %w[basalt gabbro]],
      [/\b(?:andesit\w*|lahar|dacit\w*)\b/i, %w[andesite basalt]],
      [/\b(?:granodiorit\w*|tonalit\w*|diorit\w*|monzonit\w*|batholith|pluton\w*)\b/i, %w[granodiorite granite]],
      [/\b(?:granit\w*|pegmatit\w*|feldspar|syenit\w*|gneiss)\b/i, %w[granite granodiorite]],
      [/\b(?:rhyolit\w*|obsidian|pumice|tuff|ignimbrite|ash[\s-]?flow)\b/i, %w[rhyolite andesite]],
      [/\b(?:gabbro\w*|ophiolit\w*|ultramafic|peridotit\w*|serpentinit\w*)\b/i, %w[gabbro basalt]],
      [/\b(?:limestone|calcite|carbonat\w*|dolomit\w*|marble|chalk|travertine)\b/i, %w[limestone]],
      [/\b(?:volcanic|extrusive|lava)\b/i, %w[basalt andesite rhyolite]],
      [/\b(?:wood\s*ash|plant\s*ash)\b/i, %w[wood_ash ash]]
    ].freeze

    GENERIC_LITHOLOGY_STOPWORDS = %w[
      rock rocks unit units formation member group bed beds
      sedimentary igneous metamorphic unconsolidated surficial
      deposit deposits material materials major minor incidental
      unclassified unknown none other mixed undifferentiated
      sand gravel pebble cobble boulder
    ].freeze

    TIER_BASE_CONFIDENCE = {
      local_15km: 0.55,
      regional_50km: 0.42,
      regional_50km_unfiltered: 0.30,
      lithology_global: 0.25,
      category_default: 0.15
    }.freeze

    # Realistic ceramic geological defaults (medians sum to 100.0%).
    CATEGORY_DEFAULT_RANGES = {
      "wild_clay" => {
        "SiO2"  => { "min" => 48.0, "q1" => 55.0, "median" => 59.0, "q3" => 63.0, "max" => 70.0, "iqr" => 8.0 },
        "Al2O3" => { "min" => 12.0, "q1" => 15.5, "median" => 17.5, "q3" => 21.0, "max" => 32.0, "iqr" => 5.5 },
        "Fe2O3" => { "min" => 1.0,  "q1" => 3.5,  "median" => 5.5,  "q3" => 7.5,  "max" => 10.5, "iqr" => 4.0 },
        "CaO"   => { "min" => 0.3,  "q1" => 1.0,  "median" => 2.5,  "q3" => 4.5,  "max" => 9.0,  "iqr" => 3.5 },
        "MgO"   => { "min" => 0.3,  "q1" => 1.2,  "median" => 2.0,  "q3" => 3.0,  "max" => 5.0,  "iqr" => 1.8 },
        "Na2O"  => { "min" => 0.2,  "q1" => 1.0,  "median" => 1.8,  "q3" => 2.5,  "max" => 4.0,  "iqr" => 1.5 },
        "K2O"   => { "min" => 0.5,  "q1" => 1.8,  "median" => 2.5,  "q3" => 3.2,  "max" => 5.0,  "iqr" => 1.4 },
        "TiO2"  => { "min" => 0.3,  "q1" => 0.6,  "median" => 0.85, "q3" => 1.1,  "max" => 1.8,  "iqr" => 0.5 },
        "P2O5"  => { "min" => 0.05, "q1" => 0.1,  "median" => 0.2,  "q3" => 0.3,  "max" => 0.6,  "iqr" => 0.2 },
        "MnO"   => { "min" => 0.02, "q1" => 0.06, "median" => 0.15, "q3" => 0.25, "max" => 0.5,  "iqr" => 0.19 },
        "LOI"   => { "min" => 3.5,  "q1" => 5.5,  "median" => 8.0,  "q3" => 10.5, "max" => 14.0, "iqr" => 5.0 }
      }.freeze,
      "crushed_rock" => {
        "SiO2"  => { "min" => 48.0, "q1" => 55.0, "median" => 61.5, "q3" => 68.0, "max" => 75.0, "iqr" => 13.0 },
        "Al2O3" => { "min" => 12.0, "q1" => 14.5, "median" => 16.0, "q3" => 17.5, "max" => 20.0, "iqr" => 3.0 },
        "Fe2O3" => { "min" => 1.5,  "q1" => 3.5,  "median" => 6.0,  "q3" => 9.5,  "max" => 14.0, "iqr" => 6.0 },
        "CaO"   => { "min" => 1.0,  "q1" => 3.0,  "median" => 5.5,  "q3" => 8.5,  "max" => 12.0, "iqr" => 5.5 },
        "MgO"   => { "min" => 0.5,  "q1" => 1.5,  "median" => 3.0,  "q3" => 5.0,  "max" => 8.0,  "iqr" => 3.5 },
        "Na2O"  => { "min" => 1.5,  "q1" => 2.5,  "median" => 3.4,  "q3" => 4.2,  "max" => 5.5,  "iqr" => 1.7 },
        "K2O"   => { "min" => 0.5,  "q1" => 1.4,  "median" => 2.4,  "q3" => 3.8,  "max" => 5.5,  "iqr" => 2.4 },
        "TiO2"  => { "min" => 0.2,  "q1" => 0.5,  "median" => 0.85, "q3" => 1.4,  "max" => 2.5,  "iqr" => 0.9 },
        "P2O5"  => { "min" => 0.05, "q1" => 0.12, "median" => 0.22, "q3" => 0.35, "max" => 0.6,  "iqr" => 0.23 },
        "MnO"   => { "min" => 0.04, "q1" => 0.08, "median" => 0.13, "q3" => 0.18, "max" => 0.3,  "iqr" => 0.1 },
        "LOI"   => { "min" => 0.2,  "q1" => 0.5,  "median" => 1.0,  "q3" => 1.8,  "max" => 4.0,  "iqr" => 1.3 }
      }.freeze,
      "wood_ash" => {
        "SiO2"  => { "min" => 2.0,  "q1" => 6.0,  "median" => 10.5, "q3" => 18.0, "max" => 30.0, "iqr" => 12.0 },
        "Al2O3" => { "min" => 0.5,  "q1" => 1.2,  "median" => 2.2,  "q3" => 4.0,  "max" => 8.0,  "iqr" => 2.8 },
        "Fe2O3" => { "min" => 0.3,  "q1" => 0.8,  "median" => 1.5,  "q3" => 2.8,  "max" => 5.0,  "iqr" => 2.0 },
        "CaO"   => { "min" => 25.0, "q1" => 35.0, "median" => 42.0, "q3" => 50.0, "max" => 60.0, "iqr" => 15.0 },
        "MgO"   => { "min" => 2.0,  "q1" => 4.0,  "median" => 6.5,  "q3" => 9.0,  "max" => 14.0, "iqr" => 5.0 },
        "Na2O"  => { "min" => 0.2,  "q1" => 0.6,  "median" => 1.2,  "q3" => 2.0,  "max" => 4.0,  "iqr" => 1.4 },
        "K2O"   => { "min" => 2.0,  "q1" => 5.0,  "median" => 8.5,  "q3" => 12.0, "max" => 18.0, "iqr" => 7.0 },
        "TiO2"  => { "min" => 0.02, "q1" => 0.06, "median" => 0.15, "q3" => 0.3,  "max" => 0.6,  "iqr" => 0.24 },
        "P2O5"  => { "min" => 1.0,  "q1" => 2.5,  "median" => 4.5,  "q3" => 7.0,  "max" => 11.0, "iqr" => 4.5 },
        "MnO"   => { "min" => 0.1,  "q1" => 0.4,  "median" => 0.95, "q3" => 1.8,  "max" => 3.5,  "iqr" => 1.4 },
        "LOI"   => { "min" => 10.0, "q1" => 16.0, "median" => 22.0, "q3" => 28.0, "max" => 38.0, "iqr" => 12.0 }
      }.freeze,
      "other" => {
        "SiO2"  => { "min" => 45.0, "q1" => 54.0, "median" => 60.0, "q3" => 66.0, "max" => 75.0, "iqr" => 12.0 },
        "Al2O3" => { "min" => 10.0, "q1" => 14.0, "median" => 16.5, "q3" => 19.5, "max" => 28.0, "iqr" => 5.5 },
        "Fe2O3" => { "min" => 1.0,  "q1" => 3.0,  "median" => 5.5,  "q3" => 8.0,  "max" => 12.0, "iqr" => 5.0 },
        "CaO"   => { "min" => 0.5,  "q1" => 2.0,  "median" => 4.0,  "q3" => 7.0,  "max" => 12.0, "iqr" => 5.0 },
        "MgO"   => { "min" => 0.5,  "q1" => 1.5,  "median" => 2.5,  "q3" => 4.0,  "max" => 7.0,  "iqr" => 2.5 },
        "Na2O"  => { "min" => 0.5,  "q1" => 1.5,  "median" => 2.5,  "q3" => 3.5,  "max" => 5.0,  "iqr" => 2.0 },
        "K2O"   => { "min" => 0.5,  "q1" => 1.5,  "median" => 2.5,  "q3" => 3.5,  "max" => 5.0,  "iqr" => 2.0 },
        "TiO2"  => { "min" => 0.2,  "q1" => 0.5,  "median" => 0.85, "q3" => 1.2,  "max" => 2.0,  "iqr" => 0.7 },
        "P2O5"  => { "min" => 0.05, "q1" => 0.1,  "median" => 0.2,  "q3" => 0.35, "max" => 0.7,  "iqr" => 0.25 },
        "MnO"   => { "min" => 0.02, "q1" => 0.07, "median" => 0.15, "q3" => 0.22, "max" => 0.4,  "iqr" => 0.15 },
        "LOI"   => { "min" => 0.5,  "q1" => 2.5,  "median" => 5.3,  "q3" => 8.5,  "max" => 14.0, "iqr" => 6.0 }
      }.freeze
    }.freeze

    def self.call(user_sample)
      new(user_sample).call
    end

    def initialize(user_sample)
      @user_sample = user_sample
      @reasoning_log = []
    end

    def call
      raise ArgumentError, "user_sample is required" if @user_sample.nil?

      category = (@user_sample.material_category || "other").to_s
      lithology_terms = Array(@user_sample.geologic_unit&.lithology_terms)
      lat = @user_sample.latitude
      lng = @user_sample.longitude

      filter_plan = build_filter_plan(category, lithology_terms)
      log_context(category, lithology_terms, lat, lng)

      matched_assays, strategy, search_radius = execute_tiered_search(
        lat: lat,
        lng: lng,
        category: category,
        filter_plan: filter_plan
      )

      if strategy == :category_default || matched_assays.empty?
        build_default_result(category)
      else
        build_assay_result(
          assays: matched_assays,
          strategy: strategy,
          search_radius: search_radius
        )
      end
    end

    private

    def log_context(category, lithology_terms, lat, lng)
      unit = @user_sample.geologic_unit
      unit_desc = unit ? "#{unit.name || "Unit ##{unit.macrostrat_id}"} (#{lithology_terms.any? ? lithology_terms.first(5).join(", ") : "no lithology terms"})" : "none"
      coord_desc = coordinates_present?(lat, lng) ? format("(%.4f, %.4f)", lat, lng) : "unset"
      @reasoning_log << "Baseline query initialized for category '#{category}' at #{coord_desc}; geologic unit: #{unit_desc}."
    end

    def coordinates_present?(lat, lng)
      lat.is_a?(Numeric) && lng.is_a?(Numeric) && lat.between?(-90.0, 90.0) && lng.between?(-180.0, 180.0)
    end

    def build_filter_plan(category, lithology_terms)
      category_types = CATEGORY_ROCK_TYPES.fetch(category, [])
      lithology_types = map_lithology_terms_to_rock_types(lithology_terms)
      substring_tokens = extract_substring_tokens(lithology_terms, category_types)

      preferred_types =
        if lithology_types.any? && category_types.any?
          lithology_types & category_types
        elsif lithology_types.any?
          lithology_types
        else
          []
        end

      {
        preferred_types: preferred_types.uniq,
        category_types: category_types.uniq,
        lithology_types: lithology_types.uniq,
        substring_tokens: substring_tokens
      }
    end

    def map_lithology_terms_to_rock_types(terms)
      matched = []
      terms.each do |term|
        text = term.to_s.downcase
        LITHOLOGY_KEYWORD_RULES.each do |pattern, rock_types|
          matched.concat(rock_types) if text.match?(pattern)
        end
      end
      matched.uniq
    end

    def extract_substring_tokens(terms, category_types)
      tokens = terms
        .flat_map { |term| term.to_s.downcase.scan(/[a-z][a-z_]{3,}/) }
        .reject { |token| GENERIC_LITHOLOGY_STOPWORDS.include?(token) }
        .uniq

      return tokens if category_types.empty?

      tokens.select do |token|
        mapped = map_lithology_terms_to_rock_types([token])
        mapped.empty? || (mapped & category_types).any?
      end
    end

    def execute_tiered_search(lat:, lng:, category:, filter_plan:)
      has_coords = coordinates_present?(lat, lng)

      if has_coords
        # Tier 1: 15 km radius + lithology/category filter
        tier1 = match_filtered_in_scope(
          spatial_scope(lat, lng, LOCAL_RADIUS_METERS),
          filter_plan,
          min_count: MIN_SPATIAL_MATCHES
        )
        if tier1[:assays].size >= MIN_SPATIAL_MATCHES
          @reasoning_log << "Tier 1 hit (15 km radius, #{tier1[:label]}): matched #{tier1[:assays].size} local reference assays."
          return [tier1[:assays], :local_15km, LOCAL_RADIUS_METERS]
        else
          @reasoning_log << "Tier 1 fallback (15 km radius, #{tier1[:label]}): found #{tier1[:assays].size} assay(s) (minimum #{MIN_SPATIAL_MATCHES} required); expanding to 50 km."
        end

        # Tier 2: 50 km radius + lithology/category filter
        tier2 = match_filtered_in_scope(
          spatial_scope(lat, lng, REGIONAL_RADIUS_METERS),
          filter_plan,
          min_count: MIN_SPATIAL_MATCHES
        )
        if tier2[:assays].size >= MIN_SPATIAL_MATCHES
          @reasoning_log << "Tier 2 hit (50 km radius, #{tier2[:label]}): matched #{tier2[:assays].size} regional reference assays."
          return [tier2[:assays], :regional_50km, REGIONAL_RADIUS_METERS]
        else
          @reasoning_log << "Tier 2 fallback (50 km radius, #{tier2[:label]}): found #{tier2[:assays].size} assay(s) (minimum #{MIN_SPATIAL_MATCHES} required)."
        end

        # Tier 3: 50 km radius unfiltered (skipped for botanical wood_ash so bedrock doesn't contaminate ash chemistry)
        if category == "wood_ash"
          @reasoning_log << "Tier 3 skipped: unfiltered bedrock assays are chemically unrelated to 'wood_ash'; checking global category assays."
        else
          tier3 = valid_oxide_assays(spatial_scope(lat, lng, REGIONAL_RADIUS_METERS))
          if tier3.size >= MIN_SPATIAL_MATCHES
            @reasoning_log << "Tier 3 hit (50 km radius, unfiltered): matched #{tier3.size} regional assays across local rock types."
            return [tier3, :regional_50km_unfiltered, REGIONAL_RADIUS_METERS]
          else
            @reasoning_log << "Tier 3 fallback (50 km radius, unfiltered): found #{tier3.size} assay(s) (minimum #{MIN_SPATIAL_MATCHES} required); falling back to global lithology/category match."
          end
        end
      else
        @reasoning_log << "No valid GPS coordinates on sample; skipping spatial radius tiers (15 km / 50 km) and querying global reference assays."
      end

      # Tier 4: Global lithology/category-only query
      tier4 = match_filtered_in_scope(ReferenceAssay.all, filter_plan, min_count: 1)
      if tier4[:assays].any?
        @reasoning_log << "Tier 4 hit (global lithology/category, #{tier4[:label]}): matched #{tier4[:assays].size} reference assay(s)."
        return [tier4[:assays], :lithology_global, nil]
      end

      # Tier 5: Built-in geological category defaults
      @reasoning_log << "Tier 5 fallback (category defaults): no matching reference assays found; using built-in '#{category}' baseline oxide profile."
      [[], :category_default, nil]
    end

    def spatial_scope(lat, lng, radius_meters)
      ReferenceAssay.within_radius(lat, lng, radius_meters).ordered_by_distance(lat, lng)
    end

    def match_filtered_in_scope(scope, filter_plan, min_count:)
      has_preferred = filter_plan[:preferred_types].any? || filter_plan[:substring_tokens].any?
      has_category = filter_plan[:category_types].any?
      has_lithology = filter_plan[:lithology_types].any?

      best = { assays: [], label: "unconstrained" }

      if has_preferred
        preferred_scope = apply_rock_type_filter(
          scope,
          exact_types: filter_plan[:preferred_types],
          substring_tokens: filter_plan[:substring_tokens]
        )
        preferred_assays = valid_oxide_assays(preferred_scope)
        label = describe_filter("lithology+category", filter_plan[:preferred_types], filter_plan[:substring_tokens])
        best = { assays: preferred_assays, label: label }
        return best if preferred_assays.size >= min_count
      end

      if has_category
        category_scope = apply_rock_type_filter(
          scope,
          exact_types: filter_plan[:category_types],
          substring_tokens: []
        )
        category_assays = valid_oxide_assays(category_scope)
        label = describe_filter("category", filter_plan[:category_types], [])
        if category_assays.size >= best[:assays].size
          best = { assays: category_assays, label: label }
        end
        return best if category_assays.size >= min_count
      elsif has_lithology && !has_preferred
        lith_scope = apply_rock_type_filter(
          scope,
          exact_types: filter_plan[:lithology_types],
          substring_tokens: filter_plan[:substring_tokens]
        )
        lith_assays = valid_oxide_assays(lith_scope)
        label = describe_filter("lithology", filter_plan[:lithology_types], filter_plan[:substring_tokens])
        best = { assays: lith_assays, label: label }
      end

      best
    end

    def apply_rock_type_filter(scope, exact_types:, substring_tokens:)
      clauses = []
      binds = []

      if exact_types.any?
        clauses << "LOWER(reference_assays.rock_type) IN (?)"
        binds << exact_types.map(&:downcase)
      end

      substring_tokens.each do |token|
        sanitized = ActiveRecord::Base.sanitize_sql_like(token.downcase)
        clauses << "LOWER(reference_assays.rock_type) LIKE ?"
        binds << "%#{sanitized}%"
      end

      return scope.none if clauses.empty?

      scope.where(clauses.join(" OR "), *binds)
    end

    def describe_filter(kind, exact_types, substring_tokens)
      terms = (exact_types.first(4) + substring_tokens.first(3)).uniq
      terms.any? ? "#{kind}: #{terms.join(", ")}" : kind
    end

    def valid_oxide_assays(scope)
      scope.to_a.select do |assay|
        assay.oxides.is_a?(Hash) && assay.oxides.values.any? { |v| v.to_f.positive? }
      end
    end

    def build_assay_result(assays:, strategy:, search_radius:)
      oxide_ranges = {}
      raw_medians = {}

      CeramicOxides::KEYS.each do |oxide|
        values = assays.map { |assay| [assay.oxide_value(oxide) || 0.0, 0.0].max }.sort
        min_v = values.first.round(RANGE_PRECISION)
        q1_v = percentile(values, 0.25).round(RANGE_PRECISION)
        median_v = percentile(values, 0.50).round(RANGE_PRECISION)
        q3_v = percentile(values, 0.75).round(RANGE_PRECISION)
        max_v = values.last.round(RANGE_PRECISION)
        iqr_v = (q3_v - q1_v).round(RANGE_PRECISION)

        oxide_ranges[oxide] = {
          "min" => min_v,
          "q1" => q1_v,
          "median" => median_v,
          "q3" => q3_v,
          "max" => max_v,
          "iqr" => iqr_v
        }
        raw_medians[oxide] = percentile(values, 0.50)
      end

      normalized_oxides = normalize_to_exact_100(raw_medians)
      confidence = compute_confidence(
        strategy: strategy,
        sample_count: assays.size,
        oxide_ranges: oxide_ranges
      )

      rock_summary = assays.map(&:rock_type).compact.tally.sort_by { |_, count| -count }.first(4)
                           .map { |rock, count| "#{rock} (#{count})" }.join(", ")
      @reasoning_log << "Computed quartile oxide baseline from #{assays.size} assay(s) [#{rock_summary}]; confidence=#{confidence}."

      Result.new(
        oxide_ranges: oxide_ranges,
        oxides: normalized_oxides,
        confidence_score: confidence,
        sample_count: assays.size,
        search_radius_meters: search_radius,
        strategy: strategy,
        reasoning_log: @reasoning_log,
        matched_assay_ids: assays.map(&:id)
      )
    end

    def build_default_result(category)
      template = CATEGORY_DEFAULT_RANGES.fetch(category, CATEGORY_DEFAULT_RANGES["other"])
      oxide_ranges = template.transform_values(&:dup)
      raw_medians = oxide_ranges.transform_values { |stats| stats["median"] }
      normalized_oxides = normalize_to_exact_100(raw_medians)
      confidence = TIER_BASE_CONFIDENCE[:category_default]

      Result.new(
        oxide_ranges: oxide_ranges,
        oxides: normalized_oxides,
        confidence_score: confidence,
        sample_count: 0,
        search_radius_meters: nil,
        strategy: :category_default,
        reasoning_log: @reasoning_log,
        matched_assay_ids: []
      )
    end

    def percentile(sorted, quantile)
      return 0.0 if sorted.empty?
      return sorted.first.to_f if sorted.length == 1

      rank = quantile.to_f * (sorted.length - 1)
      lower_idx = rank.floor
      upper_idx = rank.ceil
      weight = rank - lower_idx

      sorted[lower_idx].to_f + (sorted[upper_idx].to_f - sorted[lower_idx].to_f) * weight
    end

    def normalize_to_exact_100(raw_medians)
      normalized = CeramicOxides.normalize(raw_medians, precision: OXIDE_PRECISION)
      return CeramicOxides::KEYS.index_with { 0.0 } if normalized.nil?

      residual = (100.0 - normalized.values.sum).round(OXIDE_PRECISION)
      if residual != 0.0
        largest_key = normalized.max_by { |_, v| v }.first
        normalized[largest_key] = (normalized[largest_key] + residual).round(OXIDE_PRECISION)
      end

      normalized
    end

    def compute_confidence(strategy:, sample_count:, oxide_ranges:)
      base = TIER_BASE_CONFIDENCE.fetch(strategy, 0.15)
      return base.round(3) if strategy == :category_default || sample_count <= 0

      count_bonus = 0.25 * (1.0 - Math.exp(-sample_count / 12.0))

      tightness_bonus =
        if sample_count >= 2
          total_iqr = oxide_ranges.values.sum { |stats| stats["iqr"].to_f }
          dispersion = (total_iqr / 30.0).clamp(0.0, 1.0)
          0.18 * (1.0 - dispersion)
        else
          0.0
        end

      (base + count_bonus + tightness_bonus).clamp(0.0, 0.95).round(3)
    end
  end
end
