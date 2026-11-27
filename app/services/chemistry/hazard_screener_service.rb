# frozen_string_literal: true

module Chemistry
  # Screens ceramic material assays, sample context, nearby mineral occurrences,
  # and nearby XRD soil mineralogy for studio health, kiln, hard-rock processing,
  # pXRF analytical blind spots, LCT pegmatite K/Rb pathfinder signals, and clay
  # mineralogy risks.
  class HazardScreenerService
    Result = Struct.new(
      :alerts,
      :highest_severity,
      :food_safe_caution,
      :k_rb_ratio,
      :summary,
      keyword_init: true
    ) do
      def food_safe_caution?
        !!food_safe_caution
      end

      def any?
        Array(alerts).any?
      end

      def danger?
        highest_severity == :danger
      end

      def warning?
        highest_severity == :warning
      end
    end

    SEVERITY_RANK = {
      danger: 3,
      warning: 2,
      info: 1
    }.freeze

    # K2O -> elemental K mass conversion factor (2 * 39.0983 / 94.196 = 0.8301).
    K2O_TO_K_FACTOR = 0.8301
    LCT_KRB_THRESHOLD = 160.0

    BARIUM_MINERALS_PATTERN = /\b(barite|witherite)\b/i
    RADIOACTIVE_MINERALS_PATTERN = /\b(monazite|carnotite)\b/i
    CHROMIUM_MINERALS_PATTERN = /\bchromite\b/i
    MANGANESE_MINERALS_PATTERN = /\bpyrolusite\b/i
    FLUORINE_MINERALS_PATTERN = /\b(fluorite|lepidolite|topaz|cryolite)\b/i
    SULFIDE_MINERALS_PATTERN = /\b(pyrite|chalcopyrite|sphalerite|galena|gypsum|barite)\b/i
    HARD_ROCK_PATTERN = /\b(granite|pegmatite|quartzite|quartz|rhyolite|basalt|andesite|flint|chert)\b/i

    NEARBY_MINERAL_RADIUS_METERS = 25_000
    NEARBY_XRD_RADIUS_METERS = 100_000

    def self.call(assay_result: nil, user_sample: nil, nearby_minerals: nil, nearby_xrd: nil)
      new(
        assay_result: assay_result,
        user_sample: user_sample,
        nearby_minerals: nearby_minerals,
        nearby_xrd: nearby_xrd
      ).call
    end

    def initialize(assay_result: nil, user_sample: nil, nearby_minerals: nil, nearby_xrd: nil)
      @assay_result = assay_result
      @user_sample = user_sample || (assay_result.respond_to?(:user_sample) ? assay_result.user_sample : nil)
      @nearby_minerals_arg = nearby_minerals
      @nearby_xrd_arg = nearby_xrd

      @oxides = normalize_hash(assay_result.respond_to?(:oxides) ? assay_result.oxides : nil)
      @minor_oxides = normalize_hash(assay_result.respond_to?(:minor_oxides) ? assay_result.minor_oxides : nil)
      @trace_ppm = normalize_trace_hash(assay_result.respond_to?(:trace_elements_ppm) ? assay_result.trace_elements_ppm : nil)

      @alerts = []
      @food_safe_caution = false
      @k_rb_ratio = nil
    end

    def call
      @mineral_terms = extract_mineral_terms(resolve_nearby_minerals)
      @xrd_data = normalize_xrd_hash(resolve_nearby_xrd)

      screen_heavy_metals_and_radioactivity!
      screen_fluorine!
      screen_sulfides!
      screen_hard_rock_processing!
      screen_pxrf_and_pegmatite_pathfinders!
      screen_xrd_mineralogy!

      sorted_alerts = @alerts.each_with_index.sort_by do |alert, idx|
        [ -SEVERITY_RANK.fetch(alert[:severity], 0), idx ]
      end.map(&:first)

      highest = sorted_alerts.first&.dig(:severity)

      Result.new(
        alerts: sorted_alerts,
        highest_severity: highest,
        food_safe_caution: @food_safe_caution,
        k_rb_ratio: @k_rb_ratio,
        summary: build_summary(sorted_alerts)
      )
    end

    private

    def screen_heavy_metals_and_radioactivity!
      if (as_ppm = trace_ppm("As")) > 50.0
        @food_safe_caution = true
        add_alert(
          severity: :danger,
          category: :health,
          code: "toxic_arsenic",
          title: "Elevated Arsenic (As)",
          detail: "Measured As #{format_ppm(as_ppm)} ppm exceeds the 50 ppm ceramic safety threshold; arsenic is acutely toxic and volatilizes during firing.",
          recommendation: "Do not use on food-contact surfaces; wear a P100 respirator for dry powder handling and fire only with strong exterior kiln exhaust."
        )
      end

      if (pb_ppm = trace_ppm("Pb")) > 100.0
        @food_safe_caution = true
        add_alert(
          severity: :danger,
          category: :health,
          code: "toxic_lead",
          title: "Elevated Lead (Pb)",
          detail: "Measured Pb #{format_ppm(pb_ppm)} ppm exceeds the 100 ppm studio threshold; lead is a cumulative heavy-metal toxin prone to acid leaching.",
          recommendation: "Exclude from functional tableware and food-contact liners; use wet processing, dust PPE, and strict studio hygiene."
        )
      end

      if (cd_ppm = trace_ppm("Cd")) > 10.0
        @food_safe_caution = true
        add_alert(
          severity: :danger,
          category: :health,
          code: "toxic_cadmium",
          title: "Elevated Cadmium (Cd)",
          detail: "Measured Cd #{format_ppm(cd_ppm)} ppm exceeds the 10 ppm safety threshold; cadmium is an acute heavy-metal toxin and carcinogen.",
          recommendation: "Strictly avoid for food surfaces; wear P100 dust protection, handle wet, and vent kiln fumes outdoors."
        )
      end

      bao_pct = effective_minor_oxide_pct("BaO", "Ba")
      ba_minerals = matched_minerals(BARIUM_MINERALS_PATTERN)
      if bao_pct > 2.0 || ba_minerals.any?
        @food_safe_caution = true
        triggers = []
        triggers << "BaO #{format_pct(bao_pct)}%" if bao_pct > 2.0
        triggers << "nearby minerals (#{ba_minerals.join(', ')})" if ba_minerals.any?
        add_alert(
          severity: :danger,
          category: :health,
          code: "barium_toxicity",
          title: "Barium Toxicity & Leaching Hazard",
          detail: "Flagged by #{triggers.join(' and ')}; high barium levels pose toxic raw-dust risk and leach soluble barium into acidic food or drink.",
          recommendation: "Do not use on food-contact interiors unless certified via acid-leach testing; wear a P100 dust mask when weighing raw material."
        )
      end

      u_ppm = trace_ppm("U")
      th_ppm = trace_ppm("Th")
      rad_minerals = matched_minerals(RADIOACTIVE_MINERALS_PATTERN)
      if u_ppm > 50.0 || th_ppm > 50.0 || rad_minerals.any?
        @food_safe_caution = true
        triggers = []
        triggers << "U #{format_ppm(u_ppm)} ppm" if u_ppm > 50.0
        triggers << "Th #{format_ppm(th_ppm)} ppm" if th_ppm > 50.0
        triggers << "nearby radioactive host minerals (#{rad_minerals.join(', ')})" if rad_minerals.any?
        add_alert(
          severity: :danger,
          category: :health,
          code: "radioactive_minerals",
          title: "Radioactive Pegmatite / Heavy-Sand Warning (U / Th)",
          detail: "Flagged by #{triggers.join(', ')}; uranium/thorium-bearing pegmatites and heavy mineral sands emit alpha/gamma radiation and radon.",
          recommendation: "Avoid indoor bulk dry storage, dry grinding, and functional food-contact ware; verify radioactivity before studio use."
        )
      end

      cr2o3_pct = effective_minor_oxide_pct("Cr2O3", "Cr")
      cr_minerals = matched_minerals(CHROMIUM_MINERALS_PATTERN)
      if cr2o3_pct > 0.5 || cr_minerals.any?
        @food_safe_caution = true
        triggers = []
        triggers << "Cr2O3 #{format_pct(cr2o3_pct)}%" if cr2o3_pct > 0.5
        triggers << "nearby chromite (#{cr_minerals.join(', ')})" if cr_minerals.any?
        add_alert(
          severity: :warning,
          category: :health,
          code: "chromium_hazard",
          title: "Chromium Cr(VI) Inhalation & Kiln Flashing Caution",
          detail: "Flagged by #{triggers.join(' and ')}; hexavalent chromium dust/fumes are hazardous and chromium vapor flashes pink onto nearby tin-white glazes.",
          recommendation: "Wear P100 PPE, vent the kiln outdoors, fire away from tin-opacified glazes, and restrict on food-contact surfaces."
        )
      end

      mno_pct = [ oxide_pct("MnO"), @minor_oxides["MnO"].to_f ].max
      mn_minerals = matched_minerals(MANGANESE_MINERALS_PATTERN)
      if mno_pct > 3.0 || mn_minerals.any?
        @food_safe_caution = true
        triggers = []
        triggers << "MnO #{format_pct(mno_pct)}%" if mno_pct > 3.0
        triggers << "nearby pyrolusite (#{mn_minerals.join(', ')})" if mn_minerals.any?
        add_alert(
          severity: :warning,
          category: :health,
          code: "manganese_hazard",
          title: "High Manganese Dust, Kiln Fumes & O2 Blistering",
          detail: "Flagged by #{triggers.join(' and ')}; manganese dust and firing fumes are neurotoxic, and MnO2 decomposition releases oxygen gas causing glaze blistering.",
          recommendation: "Wear a P100 respirator, exhaust kiln fumes outdoors, avoid on food liners, and use a drop-and-soak firing schedule to heal blisters."
        )
      end

      cuo_pct = effective_minor_oxide_pct("CuO", "Cu")
      if cuo_pct > 3.0
        @food_safe_caution = true
        add_alert(
          severity: :warning,
          category: :health,
          code: "copper_leaching",
          title: "High Copper Acid-Leaching & Kiln Flashing Risk",
          detail: "CuO #{format_pct(cuo_pct)}% exceeds 3.0 wt%; excess copper leaches readily into acidic foods and flashes onto neighboring pots in the kiln.",
          recommendation: "Keep off food-contact interior surfaces (use on decorative exteriors or dilute below 2% CuO) and allow extra kiln shelf spacing."
        )
      end

      coo_pct = effective_minor_oxide_pct("CoO", "Co")
      nio_pct = effective_minor_oxide_pct("NiO", "Ni")
      if coo_pct > 0.5 || nio_pct > 0.5
        @food_safe_caution = true
        parts = []
        parts << "CoO #{format_pct(coo_pct)}%" if coo_pct > 0.5
        parts << "NiO #{format_pct(nio_pct)}%" if nio_pct > 0.5
        add_alert(
          severity: :warning,
          category: :health,
          code: "cobalt_nickel_sensitizer",
          title: "Cobalt / Nickel Respiratory Sensitizer",
          detail: "Elevated #{parts.join(' and ')} (> 0.5 wt%); cobalt and nickel compounds are respiratory sensitizers and suspected carcinogens in studio dust.",
          recommendation: "Wear a P100 respirator and gloves when weighing dry powders, mix wet, and limit on food-contact surfaces."
        )
      end

      v2o5_pct = effective_minor_oxide_pct("V2O5", "V")
      if v2o5_pct > 0.5
        @food_safe_caution = true
        add_alert(
          severity: :danger,
          category: :health,
          code: "vanadium_toxicity",
          title: "Toxic Vanadium Pentoxide (V2O5)",
          detail: "V2O5 #{format_pct(v2o5_pct)}% exceeds 0.5 wt%; vanadium pentoxide dust and firing fumes are highly toxic respiratory irritants.",
          recommendation: "Handle only with P100 PPE and outdoor kiln exhaust; do not use in food-contact glazes."
        )
      end
    end

    def screen_fluorine!
      f_pct = effective_minor_oxide_pct("F", "F")
      f_minerals = matched_minerals(FLUORINE_MINERALS_PATTERN)
      return unless f_pct > 0.2 || f_minerals.any?

      triggers = []
      triggers << "F #{format_pct(f_pct)}%" if f_pct > 0.2
      triggers << "fluorine-bearing minerals (#{f_minerals.join(', ')})" if f_minerals.any?

      add_alert(
        severity: :danger,
        category: :kiln,
        code: "fluorine_hf_gas",
        title: "Toxic HF Kiln Gas & Element Corrosion Hazard",
        detail: "Flagged by #{triggers.join(' and ')}; fluorine releases corrosive hydrofluoric acid (HF) gas during firing, attacking kiln elements, shelves, thermocouples, and lungs.",
        recommendation: "Fire only with active forced exterior kiln ventilation; dilute heavily or pre-calcine small test quantities to protect kiln hardware."
      )
    end

    def screen_sulfides!
      so3_pct = @minor_oxides["SO3"].to_f
      s_ppm = trace_ppm("S")
      sulfide_minerals = matched_minerals(SULFIDE_MINERALS_PATTERN)
      return unless so3_pct > 0.2 || s_ppm > 2000.0 || sulfide_minerals.any?

      triggers = []
      triggers << "SO3 #{format_pct(so3_pct)}%" if so3_pct > 0.2
      triggers << "S #{format_ppm(s_ppm)} ppm" if s_ppm > 2000.0
      triggers << "sulfide/sulfate minerals (#{sulfide_minerals.join(', ')})" if sulfide_minerals.any?

      add_alert(
        severity: :warning,
        category: :kiln,
        code: "sulfide_degassing",
        title: "Sulfur / Sulfide Pinholing & SO2 Fume Risk",
        detail: "Flagged by #{triggers.join(', ')}; late-stage sulfate/sulfide breakdown causes glaze pinholing, cratering, bloating, and irritating SO2 kiln fumes.",
        recommendation: "Oxidation-roast / calcine the raw powder to 800°C with active kiln venting before mixing into glazes or clay bodies."
      )
    end

    def screen_hard_rock_processing!
      is_crushed_rock = @user_sample.respond_to?(:crushed_rock?) && @user_sample.crushed_rock?
      unit_terms = extract_geologic_unit_terms
      matched_rock = (unit_terms + @mineral_terms).select { |t| t.match?(HARD_ROCK_PATTERN) }.uniq
      return unless is_crushed_rock || matched_rock.any?

      context_bits = []
      context_bits << "crushed-rock sample category" if is_crushed_rock
      context_bits << "hard crystalline lithology/minerals (#{matched_rock.first(4).join(', ')})" if matched_rock.any?

      add_alert(
        severity: is_crushed_rock ? :warning : :info,
        category: :processing,
        code: "hard_rock_silica_processing",
        title: "Hard-Rock Respirable Silica & Milling Guidance",
        detail: "Detected #{context_bits.join(' and ')}; crushing and dry-grinding crystalline silicate rock generates hazardous respirable crystalline silica dust.",
        recommendation: "Always wet ball-mill (or crush outdoors with P100 PPE), thermal-shock calcine tough rock (~600°C quench into water) to ease comminution, and pass slurry over rare-earth magnets to strip tramp iron."
      )
    end

    def screen_pxrf_and_pegmatite_pathfinders!
      analysis_method = @assay_result.respond_to?(:analysis_method) ? @assay_result.analysis_method.to_s : ""
      if analysis_method == "pxrf"
        add_alert(
          severity: :info,
          category: :pxrf,
          code: "pxrf_light_element_blind_spot",
          title: "Handheld pXRF Light-Element & LOI Blind Spot",
          detail: "Handheld pXRF cannot detect ultra-light ceramic fluxes (Li2O, B2O3) or volatile LOI, and carries higher uncertainty on light oxides (Na2O, MgO).",
          recommendation: "Run a studio kiln weight-loss LOI test ((dry − fired) / dry × 100%) and verify suspected lithium or boron fluxes with ICP-MS or fusion XRF."
        )
      end

      k2o_pct = oxide_pct("K2O")
      rb_ppm = trace_ppm("Rb")
      if k2o_pct > 0.5 && rb_ppm.positive?
        k_ppm = (k2o_pct * K2O_TO_K_FACTOR) * 10_000.0
        @k_rb_ratio = (k_ppm / rb_ppm).round(1)
      end

      cs_ppm = trace_ppm("Cs")
      nb_ppm = trace_ppm("Nb")
      ta_ppm = trace_ppm("Ta")
      sn_ppm = trace_ppm("Sn")

      lct_triggered = (@k_rb_ratio && @k_rb_ratio < LCT_KRB_THRESHOLD) ||
        cs_ppm > 50.0 || nb_ppm > 50.0 || ta_ppm > 20.0 || sn_ppm > 50.0
      return unless lct_triggered

      pathfinder_bits = []
      pathfinder_bits << "K/Rb = #{@k_rb_ratio.round(1)}" if @k_rb_ratio
      pathfinder_bits << "Cs = #{format_ppm(cs_ppm)} ppm" if cs_ppm > 50.0
      pathfinder_bits << "Nb = #{format_ppm(nb_ppm)} ppm" if nb_ppm > 50.0
      pathfinder_bits << "Ta = #{format_ppm(ta_ppm)} ppm" if ta_ppm > 20.0
      pathfinder_bits << "Sn = #{format_ppm(sn_ppm)} ppm" if sn_ppm > 50.0

      ratio_label = @k_rb_ratio ? " (K/Rb = #{@k_rb_ratio.round(1)})" : ""
      extra_signals = pathfinder_bits.any? ? " [#{pathfinder_bits.join(', ')}]" : ""

      add_alert(
        severity: :info,
        category: :pxrf,
        code: "lct_pegmatite_pathfinder",
        title: "Fractionated LCT Pegmatite Pathfinder Signal#{ratio_label}",
        detail: "Fractionated LCT Pegmatite Pathfinder Signal#{ratio_label}: likely unmeasured Lithium (Li2O via spodumene/petalite/lepidolite)!#{extra_signals}",
        recommendation: "Test melt behavior at Cone 6–10 (lithium strongly lowers melting point and thermal expansion) and confirm Li2O via ICP-MS if precise glaze stoichiometry is required."
      )
    end

    def screen_xrd_mineralogy!
      return if @xrd_data.empty?

      smectite = xrd_pct("smectite", "montmorillonite")
      if smectite >= 15.0
        add_alert(
          severity: :warning,
          category: :mineralogy,
          code: "xrd_high_smectite",
          title: "High Smectite Clay Content (#{format_pct(smectite)}%)",
          detail: "Nearby XRD mineralogy shows #{format_pct(smectite)}% smectite (>= 15% threshold), driving high water demand, sticky plasticity, and severe drying shrinkage/cracking.",
          recommendation: "Temper with 15–30% grog, sand, or non-plastic kaolin/silt and dry greenware slowly under plastic."
        )
      end

      quartz = xrd_pct("quartz")
      if quartz >= 45.0
        add_alert(
          severity: :warning,
          category: :mineralogy,
          code: "xrd_high_quartz",
          title: "High Free Quartz (#{format_pct(quartz)}%)",
          detail: "Nearby XRD mineralogy shows #{format_pct(quartz)}% free quartz (>= 45% threshold), causing short (low-plasticity) workability and 573°C quartz-inversion cooling dunting risk.",
          recommendation: "Blend with plastic stoneware or ball clay to restore throwing strength, and cool kilns slowly across 600–500°C."
        )
      end

      calcite = xrd_pct("calcite")
      if calcite >= 5.0
        add_alert(
          severity: :warning,
          category: :mineralogy,
          code: "xrd_high_calcite",
          title: "Calcite Lime-Popping & CO2 Degassing Risk (#{format_pct(calcite)}%)",
          detail: "Nearby XRD mineralogy shows #{format_pct(calcite)}% calcite (>= 5% threshold), creating CO2 firing blisters and post-firing lime-popping spalls from coarse CaCO3 grains.",
          recommendation: "Screen slip through 80–100 mesh to remove coarse limestone particles and vent kiln thoroughly between 700–900°C."
        )
      end
    end

    def add_alert(severity:, category:, code:, title:, detail:, recommendation:)
      @alerts << {
        severity: severity,
        category: category,
        code: code,
        title: title,
        detail: detail,
        recommendation: recommendation
      }
    end

    def resolve_nearby_minerals
      return @nearby_minerals_arg unless @nearby_minerals_arg.nil?
      return [] unless defined?(MineralOccurrence) && sample_has_coordinates?

      MineralOccurrence
        .within_radius(@user_sample.latitude, @user_sample.longitude, NEARBY_MINERAL_RADIUS_METERS)
        .limit(20)
        .to_a
    rescue StandardError
      []
    end

    def resolve_nearby_xrd
      return @nearby_xrd_arg unless @nearby_xrd_arg.nil?

      if @assay_result.respond_to?(:reference_assay) &&
          @assay_result.reference_assay&.xrd_mineralogy.is_a?(Hash) &&
          @assay_result.reference_assay.xrd_mineralogy.any?
        return @assay_result.reference_assay.xrd_mineralogy
      end

      return {} unless defined?(ReferenceAssay) && sample_has_coordinates?

      nearest = ReferenceAssay
        .where("xrd_mineralogy <> '{}'::jsonb")
        .within_radius(@user_sample.latitude, @user_sample.longitude, NEARBY_XRD_RADIUS_METERS)
        .ordered_by_distance(@user_sample.latitude, @user_sample.longitude)
        .first
      nearest&.xrd_mineralogy || {}
    rescue StandardError
      {}
    end

    def sample_has_coordinates?
      @user_sample.respond_to?(:latitude) &&
        @user_sample.respond_to?(:longitude) &&
        @user_sample.latitude.present? &&
        @user_sample.longitude.present?
    end

    def extract_mineral_terms(items)
      Array(items).flat_map do |item|
        if item.respond_to?(:all_terms)
          terms = Array(item.all_terms)
          terms << item.name.to_s if item.respond_to?(:name)
          terms << item.deposit_type.to_s if item.respond_to?(:deposit_type)
          terms
        elsif item.is_a?(Hash)
          [
            *Array(item["minerals"] || item[:minerals]),
            *Array(item["commodities"] || item[:commodities]),
            item["name"] || item[:name],
            item["deposit_type"] || item[:deposit_type]
          ]
        else
          [ item.to_s ]
        end
      end.map { |t| t.to_s.strip.downcase }.reject(&:empty?).uniq
    end

    def extract_geologic_unit_terms
      return [] unless @user_sample.respond_to?(:geologic_unit) && @user_sample.geologic_unit

      unit = @user_sample.geologic_unit
      terms = []
      terms.concat(Array(unit.lithology_terms)) if unit.respond_to?(:lithology_terms)
      terms << unit.name.to_s if unit.respond_to?(:name)
      terms << unit.strat_name.to_s if unit.respond_to?(:strat_name)
      terms.map { |t| t.to_s.strip.downcase }.reject(&:empty?).uniq
    end

    def matched_minerals(pattern)
      @mineral_terms.filter_map do |term|
        match = term.match(pattern)
        match ? match[0].downcase : nil
      end.uniq
    end

    def oxide_pct(key)
      val = @oxides[key.to_s]
      val.nil? ? 0.0 : val.to_f
    end

    def effective_minor_oxide_pct(oxide_key, element_key)
      direct = @minor_oxides[oxide_key.to_s]
      return direct.to_f if !direct.nil? && direct.to_f.positive?

      direct_in_major = @oxides[oxide_key.to_s]
      return direct_in_major.to_f if !direct_in_major.nil? && direct_in_major.to_f.positive?

      ppm = trace_ppm(element_key)
      return 0.0 unless ppm.positive?

      factor = CeramicOxides::MINOR_ELEMENT_TO_OXIDE_FACTORS.dig(element_key.to_s, :factor) || 1.0
      (ppm / 10_000.0) * factor
    end

    def trace_ppm(element)
      val = @trace_ppm[element.to_s.downcase]
      val.nil? ? 0.0 : val.to_f
    end

    def xrd_pct(*keys)
      keys.map { |k| @xrd_data[k.to_s.downcase].to_f }.max || 0.0
    end

    def normalize_hash(hash)
      return {} unless hash.is_a?(Hash)

      hash.each_with_object({}) do |(k, v), acc|
        num = safe_positive_float(v)
        acc[k.to_s] = num if num
      end
    end

    def normalize_trace_hash(hash)
      return {} unless hash.is_a?(Hash)

      hash.each_with_object({}) do |(k, v), acc|
        num = safe_positive_float(v)
        acc[k.to_s.strip.downcase] = num if num
      end
    end

    def normalize_xrd_hash(hash)
      return {} unless hash.is_a?(Hash)

      hash.each_with_object({}) do |(k, v), acc|
        num = safe_positive_float(v)
        next unless num

        cleaned_key = k.to_s.strip.downcase.sub(/(?:_pct|_percent|%)\z/, "").strip
        acc[cleaned_key] = [ acc[cleaned_key].to_f, num ].max
      end
    end

    def safe_positive_float(value)
      return nil if value.nil?

      num = Float(value)
      return nil if num.nan? || num.infinite? || !num.positive?

      num
    rescue ArgumentError, TypeError
      nil
    end

    def build_summary(alerts)
      return "No studio health, kiln, or mineralogy hazards detected." if alerts.empty?

      counts = alerts.each_with_object(Hash.new(0)) { |alert, acc| acc[alert[:severity]] += 1 }
      parts = []
      parts << "#{counts[:danger]} danger" if counts[:danger].positive?
      parts << "#{counts[:warning]} warning" if counts[:warning].positive?
      parts << "#{counts[:info]} info" if counts[:info].positive?
      noun = alerts.size == 1 ? "alert" : "alerts"
      "#{parts.join(', ')} #{noun}"
    end

    def format_pct(val)
      format("%.2f", val.to_f)
    end

    def format_ppm(val)
      num = val.to_f
      num >= 100.0 ? num.round.to_s : format("%.1f", num).sub(/\.0\z/, "")
    end
  end
end
