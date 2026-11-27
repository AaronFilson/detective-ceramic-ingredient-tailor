# frozen_string_literal: true

module SamplesHelper
  OXIDE_ROLES = {
    "SiO2"  => { label: "Glass Former", badge: "bg-[#1E4E79]/10 text-[#1E4E79] border-[#1E4E79]/20" },
    "TiO2"  => { label: "Opacifier / RO2", badge: "bg-[#1E4E79]/10 text-[#1E4E79] border-[#1E4E79]/20" },
    "P2O5"  => { label: "Glass Former", badge: "bg-[#1E4E79]/10 text-[#1E4E79] border-[#1E4E79]/20" },
    "Al2O3" => { label: "Stabilizer", badge: "bg-[#B84A27]/10 text-[#963B1D] border-[#B84A27]/20" },
    "Fe2O3" => { label: "Colorant / R2O3", badge: "bg-red-900/10 text-red-900 border-red-900/20" },
    "MnO"   => { label: "RO Flux / Color", badge: "bg-amber-700/10 text-amber-900 border-amber-700/25" },
    "CaO"   => { label: "RO Flux", badge: "bg-amber-700/10 text-amber-900 border-amber-700/25" },
    "MgO"   => { label: "RO Flux", badge: "bg-amber-700/10 text-amber-900 border-amber-700/25" },
    "Na2O"  => { label: "R2O Flux", badge: "bg-emerald-800/10 text-emerald-900 border-emerald-800/20" },
    "K2O"   => { label: "R2O Flux", badge: "bg-emerald-800/10 text-emerald-900 border-emerald-800/20" },
    "LOI"   => { label: "Volatile Loss", badge: "bg-stone-200 text-stone-700 border-stone-300" }
  }.freeze

  RAW_COLOR_SWATCHES = [
    { label: "Red / Terracotta", value: "Red terracotta", swatch: "bg-[#B84A27]" },
    { label: "Buff / White", value: "Buff white", swatch: "bg-[#EFE7D6] border border-stone-300" },
    { label: "Gray", value: "Blue gray", swatch: "bg-stone-500" },
    { label: "Brown", value: "Dark brown", swatch: "bg-[#6B4423]" },
    { label: "Ochre", value: "Yellow ochre", swatch: "bg-[#C78F2A]" }
  ].freeze

  FIRED_COLOR_SWATCHES = [
    { label: "Red / Terracotta", value: "Terracotta red", swatch: "bg-[#A84020]" },
    { label: "Buff / White", value: "Cream buff", swatch: "bg-[#F3ECE0] border border-stone-300" },
    { label: "Dark Brown", value: "Chocolate brown", swatch: "bg-[#4A2C1A]" },
    { label: "Speckled Tan", value: "Speckled tan", swatch: "bg-[#C2A47D]" },
    { label: "Gray", value: "Warm stoneware gray", swatch: "bg-stone-400" }
  ].freeze

  FIRED_CONE_OPTIONS = [
    [ "Not fired yet", "" ],
    [ "Cone 06 (999 °C — Low-Fire Earthenware)", "06" ],
    [ "Cone 04 (1060 °C — Bisque / Earthenware)", "04" ],
    [ "Cone 02 (1120 °C — High Earthenware)", "02" ],
    [ "Cone 2 (1165 °C — Low Stoneware)", "2" ],
    [ "Cone 6 (1222 °C — Mid-Fire Stoneware)", "6" ],
    [ "Cone 8 (1263 °C — High-Mid Stoneware)", "8" ],
    [ "Cone 10 (1305 °C — High-Fire Stoneware / Reduction)", "10" ],
    [ "Cone 12 (1326 °C — Wood / Soda / Porcelain)", "12" ]
  ].freeze

  def geologic_unit_boundary_geojson(geologic_unit)
    return nil unless geologic_unit&.boundary.present?

    encoded = RGeo::GeoJSON.encode(geologic_unit.boundary)
    encoded.to_json if encoded.present?
  rescue StandardError
    nil
  end

  def geologic_unit_swatch_color(geologic_unit)
    color = geologic_unit&.lithology&.dig("color")
    return color if color.is_a?(String) && color.match?(/\A#[0-9a-fA-F]{3,8}\z/)

    "#1E4E79"
  end

  def material_category_label(category)
    case category.to_s
    when "wild_clay"    then "Wild Clay"
    when "crushed_rock" then "Crushed Rock"
    when "wood_ash"     then "Wood Ash"
    else "Other Material"
    end
  end

  def source_type_badge(source_type)
    case source_type.to_s
    when "verified_lab_xrf"
      { label: "Verified Lab XRF", classes: "bg-emerald-900/10 text-emerald-900 border-emerald-800/30" }
    when "verified_lab_icpms"
      { label: "Verified Lab ICP-MS", classes: "bg-emerald-900/10 text-emerald-900 border-emerald-800/30" }
    else
      { label: "Spatial Heuristic Estimate", classes: "bg-[#1E4E79]/10 text-[#1E4E79] border-[#1E4E79]/25" }
    end
  end

  def confidence_presentation(score)
    val = score.to_f.clamp(0.0, 1.0)
    pct = (val * 100).round

    if val >= 0.72
      { pct: pct, tier: "High", dot: "bg-emerald-600", badge: "bg-emerald-50 text-emerald-900 border-emerald-200", bar: "bg-emerald-600" }
    elsif val >= 0.50
      { pct: pct, tier: "Moderate", dot: "bg-amber-600", badge: "bg-amber-50 text-amber-900 border-amber-200", bar: "bg-amber-600" }
    else
      { pct: pct, tier: "Exploratory", dot: "bg-[#B84A27]", badge: "bg-orange-50 text-[#963B1D] border-orange-200", bar: "bg-[#B84A27]" }
    end
  end

  def oxide_role(key)
    OXIDE_ROLES.fetch(key.to_s, { label: "Oxide", badge: "bg-stone-100 text-stone-700 border-stone-200" })
  end

  def oxide_range_bar(key, value, ranges_hash)
    entry = ranges_hash.is_a?(Hash) ? (ranges_hash[key.to_s] || {}) : {}
    val = value.to_f
    min_v = entry["min"].nil? ? val : entry["min"].to_f
    max_v = entry["max"].nil? ? val : entry["max"].to_f
    med_v = entry["median"].nil? ? val : entry["median"].to_f
    q1_v  = entry["q1"].nil? ? min_v : entry["q1"].to_f
    q3_v  = entry["q3"].nil? ? max_v : entry["q3"].to_f

    # Scale axis cleanly so both major (SiO2 ~60%) and trace oxides (TiO2 ~1%) visualize clearly
    axis_max = [ max_v, val, key.to_s == "SiO2" ? 80.0 : (max_v > 20.0 ? 50.0 : (max_v > 8.0 ? 20.0 : 10.0)) ].max
    axis_max = 1.0 if axis_max <= 0.0

    pct = ->(v) { ((v.clamp(0.0, axis_max) / axis_max) * 100.0).round(1) }

    whisker_min = [ min_v, val ].min
    whisker_max = [ max_v, val ].max
    min_pct = pct.call(whisker_min)
    max_pct = pct.call(whisker_max)
    q1_pct  = pct.call(q1_v)
    q3_pct  = pct.call(q3_v)
    val_pct = pct.call(val)

    {
      min: min_v,
      q1: q1_v,
      median: med_v,
      q3: q3_v,
      max: max_v,
      min_pct: min_pct,
      whisker_width: [ (max_pct - min_pct).round(1), 1.5 ].max,
      q1_pct: q1_pct,
      iqr_width: [ (q3_pct - q1_pct).round(1), 2.0 ].max,
      val_pct: val_pct
    }
  end

  def si_al_interpretation(ratio)
    return "Insufficient Al2O3 for molar ratio" if ratio.nil?

    val = ratio.to_f
    if val < 3.5
      "High-Alumina Refractory / Kaolinic"
    elsif val < 6.0
      "Stoneware Clay / Matte Ceramic Band"
    elsif val < 9.5
      "Satin-to-Gloss Glaze / High-Silica Body"
    else
      "Silica-Rich / Vitreous Glass Former"
    end
  end

  def classify_reasoning_entry(entry)
    text = entry.is_a?(Hash) ? (entry["message"] || entry["detail"] || entry.values.join(" — ")) : entry.to_s
    down = text.downcase

    tag = if down.match?(/vinegar|carbonate|caco3|fizz/)
      { label: "Vinegar / CaCO3", classes: "bg-amber-100 text-amber-950 border-amber-300" }
    elsif down.match?(/color|fe2o3|iron|terracotta|buff|burnout/)
      { label: "Iron / Color", classes: "bg-red-100 text-red-950 border-red-200" }
    elsif down.match?(/cone|melt|bloat|vitrif|refractor|fired/)
      { label: "Thermal / Cone", classes: "bg-orange-100 text-orange-950 border-orange-200" }
    elsif down.match?(/plastic|kaolin|feldspar|quartz/)
      { label: "Plasticity", classes: "bg-emerald-100 text-emerald-950 border-emerald-200" }
    elsif down.match?(/slak|shale|disintegrat/)
      { label: "Slaking", classes: "bg-teal-100 text-teal-950 border-teal-200" }
    elsif down.match?(/spatial|radius|km|assay|macrostrat|lithology|baseline|fallback|default/)
      { label: "Spatial Baseline", classes: "bg-[#1E4E79]/10 text-[#1E4E79] border-[#1E4E79]/25" }
    else
      { label: "Inference", classes: "bg-stone-200 text-stone-800 border-stone-300" }
    end

    { text: text, tag: tag }
  end

  def format_oxide_pct(val)
    format("%.2f%%", val.to_f)
  end

  def format_umf_mol(val)
    format("%.3f", val.to_f)
  end

  # Practical ceramic studio body-fit & firing guidance matching Glaze Vault's body checks
  # (e.g., maxDryingShrinkage = 7.5% and boiling-water absorption vitrification tiers).
  def body_fit_assessment(field_observation)
    return [] if field_observation.nil?

    badges = []

    if field_observation.boiling_water_absorption_percent.present?
      absorption = field_observation.boiling_water_absorption_percent.to_f
      badges << if absorption <= 0.5
        {
          key: :absorption,
          label: "Porcelain / Vitreous",
          detail: "Boiling absorption #{format('%.1f%%', absorption)} (<= 0.5%)",
          severity: :good,
          classes: "bg-emerald-100 text-emerald-900 border-emerald-300"
        }
      elsif absorption <= 3.0
        {
          key: :absorption,
          label: "Vitreous Stoneware (Functional)",
          detail: "Boiling absorption #{format('%.1f%%', absorption)} (0.5–3.0%)",
          severity: :good,
          classes: "bg-teal-100 text-teal-900 border-teal-300"
        }
      elsif absorption <= 6.0
        {
          key: :absorption,
          label: "Semi-Vitreous",
          detail: "Boiling absorption #{format('%.1f%%', absorption)} (3.0–6.0%)",
          severity: :caution,
          classes: "bg-amber-100 text-amber-950 border-amber-300"
        }
      else
        {
          key: :absorption,
          label: "Porous Earthenware / Weeping Risk",
          detail: "Boiling absorption #{format('%.1f%%', absorption)} (> 6.0%)",
          severity: :warning,
          classes: "bg-red-100 text-red-900 border-red-300"
        }
      end
    end

    if field_observation.drying_shrinkage_percent.present?
      dry_shrink = field_observation.drying_shrinkage_percent.to_f
      if dry_shrink > 7.5
        badges << {
          key: :drying_shrinkage,
          label: "High Drying Crack/Warp Risk",
          detail: "Drying shrinkage #{format('%.1f%%', dry_shrink)} (> 7.5% Glaze Vault limit)",
          severity: :warning,
          classes: "bg-red-100 text-red-900 border-red-300"
        }
      else
        badges << {
          key: :drying_shrinkage,
          label: "Safe Drying Shrinkage",
          detail: "Drying shrinkage #{format('%.1f%%', dry_shrink)} (<= 7.5%)",
          severity: :good,
          classes: "bg-stone-100 text-stone-700 border-stone-300"
        }
      end
    end

    total_shrink = field_observation.effective_total_shrinkage
    if total_shrink.present? && total_shrink > 15.0
      badges << {
        key: :total_shrinkage,
        label: "High Total Shrinkage",
        detail: "Effective total shrinkage #{format('%.1f%%', total_shrink)} (> 15.0%)",
        severity: :caution,
        classes: "bg-amber-100 text-amber-950 border-amber-300"
      }
    end

    if field_observation.water_of_plasticity.present? && field_observation.water_of_plasticity.to_f > 35.0
      wop = field_observation.water_of_plasticity.to_f
      badges << {
        key: :water_of_plasticity,
        label: "High Water Demand",
        detail: "Water of plasticity #{format('%.1f%%', wop)} (> 35.0%)",
        severity: :caution,
        classes: "bg-amber-100 text-amber-950 border-amber-300"
      }
    end

    badges
  end

  # Plain path strings so views render cleanly before Agent 5's export routes merge.
  def export_glazecalc_path(sample, download: false)
    base = "/samples/#{sample.id}/export/glazecalc.json"
    download ? "#{base}?download=1" : base
  end

  def export_glaze_vault_path(sample, download: false)
    base = "/samples/#{sample.id}/export/glaze_vault.json"
    download ? "#{base}?download=1" : base
  end

  def api_material_path(sample)
    "/api/v1/materials/#{sample.id}"
  end
end
