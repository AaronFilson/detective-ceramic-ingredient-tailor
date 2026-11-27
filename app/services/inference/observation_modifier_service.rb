# frozen_string_literal: true

module Inference
  class ObservationModifierService
    Result = Struct.new(
      :oxides,
      :oxide_ranges,
      :umf_formula,
      :reasoning_log,
      :confidence_adjustment,
      keyword_init: true
    )

    # Stoichiometric mass ratio CO2 / CaO for CaCO3 -> CaO + CO2 (44.01 / 56.08)
    CACO3_LOI_PER_CAO = 0.785

    IRON_RICH_COLOR_PATTERN = /\b(?:red|reddish|brown|brownish|terracotta|terra[\s-]?cotta|rust|rusty|mahogany|ochre|ocher|dark|chocolate|iron|brick|sienna|umber|maroon|burgundy|auburn)\b/i
    LOW_IRON_COLOR_PATTERN  = /\b(?:buff|white|ivory|cream|creamy|pale|off[\s-]?white|porcelain|bone|chalky[\s-]?white)\b/i
    STRONG_IRON_COLOR_PATTERN = /\b(?:red|reddish|terracotta|terra[\s-]?cotta|rust|rusty|mahogany|ochre|ocher|chocolate|iron|brick|sienna|umber|maroon)\b/i

    MAX_CONFIDENCE_ADJUSTMENT = 0.25

    def self.call(baseline_ranges, field_observation)
      new(baseline_ranges, field_observation).call
    end

    # Parses Orton pyrometric cone strings into signed numeric scale:
    #   "022".."01" => -22..-1
    #   "1".."14"   => 1..14
    def self.parse_cone(raw_cone)
      return nil if raw_cone.nil?

      str = raw_cone.to_s.strip
      return nil if str.empty?

      cleaned = str.sub(/\A(?:cone|c|Δ|\^|#)\s*/i, "").strip
      return nil unless cleaned.match?(/\A0\d{1,2}\z|\A-?\d{1,2}\z/)

      if cleaned.start_with?("0") && cleaned.length >= 2
        num = -cleaned[1..].to_i
        num.between?(-22, -1) ? num : nil
      else
        num = cleaned.to_i
        return num if num.between?(-22, -1) || num.between?(1, 14)

        nil
      end
    end

    def self.normalize_exact_oxides(raw_oxides, pinned: {})
      values = CeramicOxides::KEYS.each_with_object({}) do |key, acc|
        num = raw_oxides[key].to_f
        acc[key] = num.positive? ? num : 0.0
      end

      pinned_clean = pinned.each_with_object({}) do |(k, v), acc|
        key = k.to_s
        next unless CeramicOxides::KEYS.include?(key)

        acc[key] = v.to_f.clamp(0.0, 100.0).round(2)
      end

      pinned_sum = pinned_clean.values.sum
      remaining_target = (100.0 - pinned_sum).clamp(0.0, 100.0)
      unpinned_keys = CeramicOxides::KEYS - pinned_clean.keys
      unpinned_total = unpinned_keys.sum { |key| values[key] }

      rounded = pinned_clean.dup

      if unpinned_total.positive? && remaining_target.positive?
        scale = remaining_target / unpinned_total
        unpinned_keys.each do |key|
          rounded[key] = (values[key] * scale).round(2)
        end
      else
        unpinned_keys.each { |key| rounded[key] = 0.0 }
      end

      total_rounded = rounded.values.sum
      if total_rounded.positive?
        residual = (100.0 - total_rounded).round(2)
        if residual != 0.0
          adjust_pool = unpinned_keys.select { |key| rounded[key].positive? }
          adjust_pool = CeramicOxides::KEYS if adjust_pool.empty?
          largest_key = adjust_pool.max_by { |key| rounded[key] }
          rounded[largest_key] = [rounded[largest_key] + residual, 0.0].max.round(2)
        end
      end

      CeramicOxides::KEYS.each_with_object({}) { |key, acc| acc[key] = rounded[key] }
    end

    def initialize(baseline_ranges, field_observation)
      @baseline_ranges = parse_baseline_ranges(baseline_ranges)
      @observation = field_observation
      @working = @baseline_ranges.transform_values { |range| range["median"] }
      @reasoning_log = []
      @confidence_adjustment = 0.0
      @fe_max_cap = nil
      @fe_min_floor = nil
      @fe_band_max = nil
      @melt_boosted_fe = false
    end

    def call
      if @observation
        apply_vinegar_fizz_rule!
        apply_color_rule!
        apply_melt_state_and_cone_rule!
        apply_plasticity_rule!
        apply_slaking_rule!
      end

      clamp_non_negative!
      final_oxides = finalize_normalized_oxides
      updated_ranges = build_updated_ranges(final_oxides)
      umf = Chemistry::UmfCalculator.call(final_oxides)

      Result.new(
        oxides: final_oxides,
        oxide_ranges: updated_ranges,
        umf_formula: umf,
        reasoning_log: @reasoning_log,
        confidence_adjustment: @confidence_adjustment.clamp(0.0, MAX_CONFIDENCE_ADJUSTMENT).round(3)
      )
    end

    private

    def apply_vinegar_fizz_rule!
      fizz = read_obs(:vinegar_fizz)&.to_s
      return if fizz.nil? || fizz.empty? || fizz == "none"

      cao_range = @baseline_ranges["CaO"]
      upper_spread = [cao_range["q3"] - cao_range["median"], 0.0].max

      case fizz
      when "vigorous"
        delta_cao = [upper_spread, 5.0].max.clamp(3.0, 8.0)
        delta_loi = (delta_cao * CACO3_LOI_PER_CAO).clamp(2.0, 7.0)
        @working["CaO"] += delta_cao
        @working["LOI"] += delta_loi
        @confidence_adjustment += 0.08
        @reasoning_log << format(
          "Vigorous vinegar fizz indicates substantial calcium carbonate (CaCO3): shifted CaO +%.2f%% and LOI +%.2f%% via CaCO3 decomposition stoichiometry.",
          delta_cao, delta_loi
        )
      when "slight"
        delta_cao = [upper_spread, 1.75].max.clamp(1.0, 2.5)
        delta_loi = (delta_cao * CACO3_LOI_PER_CAO).clamp(0.75, 2.2)
        @working["CaO"] += delta_cao
        @working["LOI"] += delta_loi
        @confidence_adjustment += 0.04
        @reasoning_log << format(
          "Slight vinegar fizz indicates minor carbonate presence (CaCO3): shifted CaO +%.2f%% and LOI +%.2f%%.",
          delta_cao, delta_loi
        )
      end
    end

    def apply_color_rule!
      raw_color = read_obs(:raw_color)&.to_s&.strip
      fired_color = read_obs(:fired_color)&.to_s&.strip

      raw_class = classify_color(raw_color)
      fired_class = classify_color(fired_color)
      return if raw_class.nil? && fired_class.nil?

      # Fired color overrides dark raw clay when organic carbon burns out cleanly
      if raw_class == :iron_rich && fired_class == :low_iron
        target_fe = [@baseline_ranges["Fe2O3"]["q1"], 1.2].min.clamp(0.3, 1.35)
        @working["Fe2O3"] = [@working["Fe2O3"], target_fe].min
        @working["LOI"] += 1.5
        @fe_max_cap = 1.4
        @confidence_adjustment += 0.08
        @reasoning_log << format(
          "Fired color ('%s') overrides dark raw color ('%s'): organic carbon burnout inferred — capped Fe2O3 below 1.5%% (target %.2f%%) and increased LOI +1.50%%.",
          fired_color, raw_color, @working["Fe2O3"]
        )
        return
      end

      effective_class = fired_class || raw_class
      source_description = if raw_class == :low_iron && fired_class == :iron_rich
        "Fired color ('#{fired_color}') overrides pale raw color ('#{raw_color}')"
      elsif raw_class && fired_class && raw_class == fired_class
        "Raw color ('#{raw_color}') and fired color ('#{fired_color}')"
      elsif fired_class
        "Fired color ('#{fired_color}')"
      else
        "Raw color ('#{raw_color}')"
      end

      case effective_class
      when :iron_rich
        fe_q3 = @baseline_ranges["Fe2O3"]["q3"]
        current_fe = @working["Fe2O3"]
        target_fe = if current_fe < 4.0
          [fe_q3, 5.8].max.clamp(4.5, 8.5)
        elsif current_fe > 9.0
          8.8
        else
          [current_fe, [fe_q3, 8.5].min].max.clamp(4.2, 8.8)
        end

        @working["Fe2O3"] = target_fe
        @fe_min_floor = 4.0
        @fe_band_max = 9.0
        @confidence_adjustment += (fired_class ? 0.07 : 0.04)
        @reasoning_log << format(
          "%s indicates iron-bearing clay: shifted Fe2O3 toward upper quartile to %.2f%% (4.0%%–9.0%% band).",
          source_description, target_fe
        )
      when :low_iron
        target_fe = [@baseline_ranges["Fe2O3"]["q1"], 1.2].min.clamp(0.3, 1.35)
        @working["Fe2O3"] = [@working["Fe2O3"], target_fe].min
        @fe_max_cap = 1.4
        @confidence_adjustment += (fired_class ? 0.07 : 0.04)
        @reasoning_log << format(
          "%s indicates low-iron body: capped Fe2O3 below 1.5%% (target %.2f%%).",
          source_description, @working["Fe2O3"]
        )
      end
    end

    def apply_melt_state_and_cone_rule!
      melt_state = read_obs(:melt_state)&.to_s
      return if melt_state.nil? || melt_state.empty?

      raw_cone = read_obs(:fired_cone)&.to_s&.strip
      cone_num = self.class.parse_cone(raw_cone)
      cone_label = cone_num ? "Cone #{raw_cone}" : "unspecified firing cone"

      case melt_state
      when "melted_fluid"
        if cone_num.nil? || cone_num <= 6
          @working["Na2O"] += 1.5
          @working["K2O"] += 2.0
          @working["CaO"] += 2.5
          if @fe_max_cap.nil?
            @working["Fe2O3"] += 1.5
            @melt_boosted_fe = true
            flux_summary = "alkali fluxes (Na2O +1.50%, K2O +2.00%), CaO (+2.50%), and Fe2O3 (+1.50%)"
          else
            @working["Na2O"] += 0.75
            @working["K2O"] += 0.75
            flux_summary = "alkali fluxes (Na2O +2.25%, K2O +2.75%) and CaO (+2.50%) while honoring low-iron cap"
          end
          @confidence_adjustment += 0.08
          @reasoning_log << "Melted/fluid behavior at #{cone_label} indicates strong low-to-mid temperature fluxing: boosted #{flux_summary}."
        else
          @working["Na2O"] += 0.75
          @working["K2O"] += 1.0
          @working["CaO"] += 1.5
          @confidence_adjustment += 0.05
          @reasoning_log << "Melted/fluid behavior at high fire (#{cone_label}) indicates active high-temperature fluxing: boosted Na2O (+0.75%), K2O (+1.00%), and CaO (+1.50%)."
        end
      when "bloated"
        if cone_num.nil? || cone_num <= 6
          @working["Na2O"] += 1.0
          @working["K2O"] += 1.5
          @working["CaO"] += 1.0
          @working["LOI"] += 1.0
          if @fe_max_cap.nil?
            @working["Fe2O3"] += 2.0
            @melt_boosted_fe = true
            flux_summary = "Fe2O3 (+2.00%), alkali fluxes (Na2O +1.00%, K2O +1.50%), CaO (+1.00%), and LOI (+1.00%)"
          else
            @working["Na2O"] += 0.5
            @working["K2O"] += 0.5
            flux_summary = "alkali fluxes (Na2O +1.50%, K2O +2.00%), CaO (+1.00%), and LOI (+1.00%)"
          end
          @confidence_adjustment += 0.07
          @reasoning_log << "Bloated melt state at #{cone_label} indicates early vitrification with trapped gas evolution: boosted #{flux_summary}."
        else
          @working["Na2O"] += 0.5
          @working["K2O"] += 0.75
          @working["LOI"] += 0.75
          if @fe_max_cap.nil?
            @working["Fe2O3"] += 1.25
            @melt_boosted_fe = true
          end
          @confidence_adjustment += 0.05
          @reasoning_log << "Bloated melt state at high fire (#{cone_label}) indicates over-firing gas evolution: modestly increased iron/alkali fluxes and LOI."
        end
      when "refractory_chalky"
        if cone_num && cone_num >= 8
          @working["Al2O3"] += 5.5
          @working["SiO2"] += 3.0
          @working["Na2O"] *= 0.5
          @working["K2O"] *= 0.5
          @working["CaO"] *= 0.5
          @working["MgO"] *= 0.6
          @confidence_adjustment += 0.09
          @reasoning_log << "Refractory/chalky state at high fire (#{cone_label}) indicates a low-flux refractory clay (kaolin/fireclay): boosted Al2O3 (+5.50%) and SiO2 (+3.00%) while dampening Na2O, K2O, CaO, and MgO fluxes."
        else
          @working["Al2O3"] += 1.5
          @working["SiO2"] += 1.0
          @working["Na2O"] *= 0.85
          @working["K2O"] *= 0.85
          @confidence_adjustment += 0.04
          @reasoning_log << "Refractory/chalky state at #{cone_label} suggests limited early fluxing: modestly increased Al2O3 (+1.50%) and SiO2 (+1.00%) while slightly dampening alkali fluxes."
        end
      when "vitrified_tight"
        if cone_num && cone_num <= -1
          @working["Na2O"] += 0.5
          @working["K2O"] += 0.75
          @working["CaO"] += 0.75
          @confidence_adjustment += 0.05
          @reasoning_log << "Tight vitrification at low fire (#{cone_label}) indicates flux-rich earthenware maturation: modestly boosted Na2O (+0.50%), K2O (+0.75%), and CaO (+0.75%)."
        else
          @confidence_adjustment += 0.06
          @reasoning_log << "Tight vitrification at #{cone_label} confirms balanced stoneware vitrification (silica/alumina and flux ratios corroborated)."
        end
      end
    end

    def apply_plasticity_rule!
      plasticity = read_obs(:plasticity)&.to_s
      return if plasticity.nil? || plasticity.empty?

      case plasticity
      when "high_plastic"
        @working["Al2O3"] += 3.0
        @working["LOI"] += 2.2
        si_trim = [@working["SiO2"], 2.5].min
        @working["SiO2"] -= si_trim
        @confidence_adjustment += 0.05
        @reasoning_log << format(
          "High plasticity weights composition toward kaolinite/illite clay ratios: increased Al2O3 (+3.00%%) and LOI (+2.20%%), trimmed free SiO2 (-%.2f%%).",
          si_trim
        )
      when "short_non_plastic"
        @working["SiO2"] += 3.0
        @working["K2O"] += 1.0
        @working["Na2O"] += 0.75
        loi_drop = [@working["LOI"], 3.0].min
        @working["LOI"] -= loi_drop
        @confidence_adjustment += 0.05
        @reasoning_log << format(
          "Short/non-plastic workability weights composition toward feldspar/quartz rock profiles: increased SiO2 (+3.00%%), K2O (+1.00%%), and Na2O (+0.75%%), reduced LOI (-%.2f%%).",
          loi_drop
        )
      when "moderate"
        @confidence_adjustment += 0.02
        @reasoning_log << "Moderate plasticity corroborates a balanced clay/silt ceramic body profile."
      end
    end

    def apply_slaking_rule!
      slaking = read_obs(:slaking_behavior)&.to_s
      return if slaking.nil? || slaking.empty?

      case slaking
      when "fast_disintegration"
        @working["LOI"] += 0.8
        @confidence_adjustment += 0.03
        @reasoning_log << "Fast slaking disintegration indicates unconsolidated clay/silt dispersion: slightly reinforced LOI (+0.80%)."
      when "no_slake"
        loi_drop = [@working["LOI"], 1.0].min
        @working["LOI"] -= loi_drop
        @confidence_adjustment += 0.03
        @reasoning_log << format(
          "Non-slaking behavior indicates indurated shale or rock matrix: slightly reduced LOI (-%.2f%%).",
          loi_drop
        )
      when "slow_flake"
        @confidence_adjustment += 0.02
        @reasoning_log << "Slow-flaking slaking behavior suggests moderately consolidated clay/shale."
      end
    end

    def clamp_non_negative!
      CeramicOxides::KEYS.each do |key|
        @working[key] = 0.0 if @working[key] < 0.0
      end
    end

    def finalize_normalized_oxides
      normalized = self.class.normalize_exact_oxides(@working)
      pinned = {}

      if @fe_max_cap && normalized["Fe2O3"] > @fe_max_cap
        pinned["Fe2O3"] = @fe_max_cap
      elsif @fe_min_floor && normalized["Fe2O3"] < @fe_min_floor
        pinned["Fe2O3"] = @fe_min_floor
      elsif @fe_band_max && !@melt_boosted_fe && normalized["Fe2O3"] > @fe_band_max
        pinned["Fe2O3"] = @fe_band_max
      end

      return normalized if pinned.empty?

      self.class.normalize_exact_oxides(@working, pinned: pinned)
    end

    def build_updated_ranges(final_oxides)
      CeramicOxides::KEYS.each_with_object({}) do |key, acc|
        base = @baseline_ranges[key]
        new_median = final_oxides[key]

        lower_span = [base["median"] - base["min"], 0.0].max
        q1_span    = [base["median"] - base["q1"], 0.0].max
        q3_span    = [base["q3"] - base["median"], 0.0].max
        upper_span = [base["max"] - base["median"], 0.0].max

        r_min = (new_median - lower_span).clamp(0.0, new_median)
        r_q1  = (new_median - q1_span).clamp(r_min, new_median)
        r_q3  = (new_median + q3_span).clamp(new_median, 100.0)
        r_max = (new_median + upper_span).clamp(r_q3, 100.0)

        if key == "Fe2O3" && @fe_max_cap
          cap_ceiling = [new_median, 1.5].max
          r_max = [r_max, cap_ceiling].min
          r_q3  = [r_q3, r_max].min
        end

        r_min = r_min.round(2)
        r_q1  = r_q1.round(2).clamp(r_min, new_median)
        r_max = r_max.round(2)
        r_q3  = r_q3.round(2).clamp(new_median, r_max)

        acc[key] = {
          "min"    => r_min,
          "q1"     => r_q1,
          "median" => new_median,
          "q3"     => r_q3,
          "max"    => r_max,
          "iqr"    => (r_q3 - r_q1).round(2)
        }
      end
    end

    def parse_baseline_ranges(raw_ranges)
      source = (raw_ranges.is_a?(Hash) ? raw_ranges : {}).transform_keys(&:to_s)

      CeramicOxides::KEYS.each_with_object({}) do |key, acc|
        entry = source[key]
        acc[key] = if entry.is_a?(Hash)
          h = entry.transform_keys(&:to_s)
          raw_min = h["min"]&.to_f
          raw_max = h["max"]&.to_f
          median = if !h["median"].nil?
            h["median"].to_f
          elsif raw_min && raw_max
            (raw_min + raw_max) / 2.0
          else
            (h["value"] || 0.0).to_f
          end
          median = [median, 0.0].max

          min_val = raw_min ? [raw_min, 0.0].max : median
          max_val = raw_max ? [raw_max, 0.0].max : median
          min_val = [min_val, median].min
          max_val = [max_val, median].max

          q1_val = h["q1"].nil? ? (min_val + median) / 2.0 : h["q1"].to_f
          q3_val = h["q3"].nil? ? (median + max_val) / 2.0 : h["q3"].to_f
          q1_val = q1_val.clamp(min_val, median)
          q3_val = q3_val.clamp(median, max_val)

          {
            "min"    => min_val,
            "q1"     => q1_val,
            "median" => median,
            "q3"     => q3_val,
            "max"    => max_val,
            "iqr"    => (q3_val - q1_val).round(4)
          }
        elsif entry.is_a?(Numeric)
          val = [entry.to_f, 0.0].max
          { "min" => val, "q1" => val, "median" => val, "q3" => val, "max" => val, "iqr" => 0.0 }
        else
          { "min" => 0.0, "q1" => 0.0, "median" => 0.0, "q3" => 0.0, "max" => 0.0, "iqr" => 0.0 }
        end
      end
    end

    def classify_color(color_text)
      return nil if color_text.nil? || color_text.empty?

      is_iron = color_text.match?(IRON_RICH_COLOR_PATTERN)
      is_low  = color_text.match?(LOW_IRON_COLOR_PATTERN)

      if is_iron && is_low
        color_text.match?(STRONG_IRON_COLOR_PATTERN) ? :iron_rich : :low_iron
      elsif is_iron
        :iron_rich
      elsif is_low
        :low_iron
      end
    end

    def read_obs(attr)
      if @observation.is_a?(Hash)
        @observation[attr] || @observation[attr.to_s]
      elsif @observation.respond_to?(attr)
        @observation.public_send(attr)
      end
    end
  end
end
