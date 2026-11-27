# frozen_string_literal: true

module StullChartHelper
  CHART_WIDTH  = 560.0
  CHART_HEIGHT = 340.0
  PADDING      = { top: 22.0, right: 24.0, bottom: 44.0, left: 52.0 }.freeze

  DEFAULT_MAX_AL2O3 = 1.2
  DEFAULT_MAX_SIO2  = 10.0

  UNDERFIRED_MAX_AL2O3 = 0.30
  UNDERFIRED_MAX_SIO2  = 1.50

  STULL_ZONES = {
    unfused_refractory: {
      zone: :unfused_refractory,
      label: "Unfused / Refractory",
      short_label: "Unfused",
      description: "High Al2O3 relative to SiO2 (Si:Al < 3.5) — refractory clay or stiff, under-melted surface.",
      badge_classes: "bg-[#B84A27]/12 text-[#963B1D] border-[#B84A27]/30",
      fill: "#EFE0D6",
      fill_opacity: "0.78",
      text_color: "#8B3A21"
    },
    matte: {
      zone: :matte,
      label: "Matte",
      short_label: "Matte",
      description: "Alumina-rich matte corridor (Si:Al 3.5–6.0) — crystalline or satin-matte melt.",
      badge_classes: "bg-amber-100 text-amber-950 border-amber-300",
      fill: "#F3E5C8",
      fill_opacity: "0.76",
      text_color: "#8A5A12"
    },
    satin_gloss: {
      zone: :satin_gloss,
      label: "Satin / Gloss",
      short_label: "Satin / Gloss",
      description: "Classic Stull bright-glaze corridor (Si:Al 6.0–10.0) — balanced fluid glass former.",
      badge_classes: "bg-emerald-100 text-emerald-900 border-emerald-300",
      fill: "#D8EDE3",
      fill_opacity: "0.76",
      text_color: "#1F5C4A"
    },
    crazing_high_silica: {
      zone: :crazing_high_silica,
      label: "Crazing / High-Silica",
      short_label: "High-Silica / Crazing",
      description: "High SiO2:Al2O3 (> 10.0) — excess free silica or crazing-prone glass phase.",
      badge_classes: "bg-[#1E4E79]/12 text-[#1E4E79] border-[#1E4E79]/30",
      fill: "#DCE8F2",
      fill_opacity: "0.72",
      text_color: "#1E4E79"
    },
    underfired_high_flux: {
      zone: :underfired_high_flux,
      label: "Underfired / High-Flux",
      short_label: "High-Flux",
      description: "Very low UMF SiO2 & Al2O3 — flux-dominated (e.g., wood ash or raw flux); needs clay & silica.",
      badge_classes: "bg-rose-100 text-rose-900 border-rose-300",
      fill: "#F7D8CE",
      fill_opacity: "0.88",
      text_color: "#963B1D"
    }
  }.freeze

  def stull_zone_for(al2o3:, sio2:)
    al = al2o3.to_f
    si = sio2.to_f

    zone_key = if si < UNDERFIRED_MAX_SIO2 && al < UNDERFIRED_MAX_AL2O3
      :underfired_high_flux
    elsif al <= 0.0001
      si < UNDERFIRED_MAX_SIO2 ? :underfired_high_flux : :crazing_high_silica
    else
      ratio = si / al
      if ratio < 3.5
        :unfused_refractory
      elsif ratio < 6.0
        :matte
      elsif ratio <= 10.0
        :satin_gloss
      else
        :crazing_high_silica
      end
    end

    STULL_ZONES.fetch(zone_key).slice(:zone, :label, :description, :badge_classes)
  end

  def stull_extract_point(assay_or_umf, label: nil, kind: :active)
    return nil if assay_or_umf.nil?

    umf = if assay_or_umf.respond_to?(:umf_formula)
      assay_or_umf.umf_formula || {}
    elsif assay_or_umf.is_a?(Hash)
      assay_or_umf
    else
      {}
    end

    al = extract_umf_oxide(umf, "Al2O3", "intermediates")
    si = extract_umf_oxide(umf, "SiO2", "glass_formers")
    return nil if al.nil? || si.nil?

    ratio = if umf["si_al_ratio"].present?
      umf["si_al_ratio"].to_f
    elsif al.positive?
      (si / al).round(3)
    end

    zone = stull_zone_for(al2o3: al, sio2: si)

    {
      al2o3: al.round(4),
      sio2: si.round(4),
      si_al_ratio: ratio&.round(2),
      zone: zone,
      label: label || default_point_label(assay_or_umf, kind),
      kind: kind
    }
  end

  def stull_axis_bounds(points)
    valid = Array(points).compact
    peak_al = valid.map { |pt| pt[:al2o3].to_f }.max || 0.0
    peak_si = valid.map { |pt| pt[:sio2].to_f }.max || 0.0

    max_al = if peak_al <= DEFAULT_MAX_AL2O3 * 0.92
      DEFAULT_MAX_AL2O3
    else
      nice_ceiling(peak_al * 1.15, [ 0.2, 0.5, 1.0, 2.0, 5.0 ])
    end

    max_si = if peak_si <= DEFAULT_MAX_SIO2 * 0.92
      DEFAULT_MAX_SIO2
    else
      nice_ceiling(peak_si * 1.15, [ 1.0, 2.0, 5.0, 10.0, 20.0 ])
    end

    {
      max_al2o3: max_al,
      max_sio2: max_si,
      expanded: max_al > DEFAULT_MAX_AL2O3 || max_si > DEFAULT_MAX_SIO2
    }
  end

  def stull_plot_geometry(max_al2o3:, max_sio2:)
    plot_width = CHART_WIDTH - PADDING[:left] - PADDING[:right]
    plot_height = CHART_HEIGHT - PADDING[:top] - PADDING[:bottom]

    {
      width: CHART_WIDTH,
      height: CHART_HEIGHT,
      left: PADDING[:left],
      top: PADDING[:top],
      right: CHART_WIDTH - PADDING[:right],
      bottom: CHART_HEIGHT - PADDING[:bottom],
      plot_width: plot_width,
      plot_height: plot_height,
      max_al2o3: max_al2o3.to_f,
      max_sio2: max_sio2.to_f
    }
  end

  def stull_x(al2o3, geometry)
    max_al = [ geometry[:max_al2o3].to_f, 0.01 ].max
    fraction = al2o3.to_f.clamp(0.0, max_al) / max_al
    (geometry[:left] + fraction * geometry[:plot_width]).round(2)
  end

  def stull_y(sio2, geometry)
    max_si = [ geometry[:max_sio2].to_f, 0.01 ].max
    fraction = sio2.to_f.clamp(0.0, max_si) / max_si
    (geometry[:bottom] - fraction * geometry[:plot_height]).round(2)
  end

  def stull_shift_vector(from_point, to_point, geometry: nil)
    return nil if from_point.nil? || to_point.nil?

    delta_al = (to_point[:al2o3].to_f - from_point[:al2o3].to_f).round(4)
    delta_si = (to_point[:sio2].to_f - from_point[:sio2].to_f).round(4)
    delta_ratio = if from_point[:si_al_ratio].present? && to_point[:si_al_ratio].present?
      (to_point[:si_al_ratio].to_f - from_point[:si_al_ratio].to_f).round(2)
    end
    distance = Math.hypot(delta_al, delta_si).round(4)

    result = {
      from: from_point,
      to: to_point,
      delta_al2o3: delta_al,
      delta_sio2: delta_si,
      delta_si_al: delta_ratio,
      distance: distance,
      zone_changed: from_point.dig(:zone, :zone) != to_point.dig(:zone, :zone)
    }

    if geometry
      result[:x1] = stull_x(from_point[:al2o3], geometry)
      result[:y1] = stull_y(from_point[:sio2], geometry)
      result[:x2] = stull_x(to_point[:al2o3], geometry)
      result[:y2] = stull_y(to_point[:sio2], geometry)
    end

    result
  end

  def stull_chart_model(assay_result:, heuristic_assay: nil, verified_lab_assay: nil, baseline_assay: nil)
    active_point = stull_extract_point(assay_result, kind: :active)
    return nil if active_point.nil?

    comparison_point = nil
    vector_from = nil
    vector_to = nil

    if heuristic_assay.present? && verified_lab_assay.present? && heuristic_assay.id != verified_lab_assay.id
      heuristic_pt = stull_extract_point(heuristic_assay, label: "Spatial Heuristic", kind: :heuristic)
      lab_pt = stull_extract_point(verified_lab_assay, label: "Verified Lab", kind: :verified_lab)

      if assay_result.respond_to?(:id) && assay_result.id == verified_lab_assay.id
        active_point = lab_pt.merge(kind: :active)
        comparison_point = heuristic_pt
        vector_from = heuristic_pt
        vector_to = active_point
      else
        active_point = heuristic_pt.merge(kind: :active)
        comparison_point = lab_pt
        vector_from = active_point
        vector_to = lab_pt
      end
    elsif baseline_assay.present? && (!assay_result.respond_to?(:id) || baseline_assay.id != assay_result.id)
      comparison_point = stull_extract_point(baseline_assay, label: "Baseline Estimate", kind: :baseline)
      vector_from = comparison_point
      vector_to = active_point
    end

    points = [ comparison_point, active_point ].compact
    bounds = stull_axis_bounds(points)
    geometry = stull_plot_geometry(max_al2o3: bounds[:max_al2o3], max_sio2: bounds[:max_sio2])

    active_plotted = active_point.merge(
      cx: stull_x(active_point[:al2o3], geometry),
      cy: stull_y(active_point[:sio2], geometry)
    )

    comparison_plotted = if comparison_point
      comparison_point.merge(
        cx: stull_x(comparison_point[:al2o3], geometry),
        cy: stull_y(comparison_point[:sio2], geometry)
      )
    end

    shift_vector = if vector_from && vector_to
      stull_shift_vector(vector_from, vector_to, geometry: geometry)
    end

    {
      geometry: geometry,
      bounds: bounds,
      active_point: active_plotted,
      comparison_point: comparison_plotted,
      shift_vector: shift_vector,
      zones: build_zone_polygons(geometry),
      ratio_guides: build_ratio_guides(geometry),
      x_ticks: build_axis_ticks(bounds[:max_al2o3], 6),
      y_ticks: build_axis_ticks(bounds[:max_sio2], 5)
    }
  end

  def stull_point_tooltip(point)
    ratio_str = point[:si_al_ratio].present? ? "#{format('%.2f', point[:si_al_ratio])}:1" : "n/a"
    "#{point[:label]} — Al2O3: #{format('%.3f', point[:al2o3])}, SiO2: #{format('%.3f', point[:sio2])}, " \
      "Si:Al #{ratio_str} (#{point[:zone][:label]})"
  end

  private

  def extract_umf_oxide(umf, oxide_key, group_key)
    raw = umf.dig(group_key, oxide_key)
    raw = umf.dig("oxides", oxide_key) if raw.nil?
    raw = umf[oxide_key] if raw.nil?
    raw = umf[oxide_key.to_sym] if raw.nil?
    return nil if raw.nil?

    val = raw.to_f
    val.finite? ? [ val, 0.0 ].max : nil
  end

  def default_point_label(assay_or_umf, kind)
    if assay_or_umf.respond_to?(:verified_lab?) && assay_or_umf.verified_lab?
      "Verified Lab"
    elsif kind == :heuristic
      "Spatial Heuristic"
    elsif kind == :baseline
      "Baseline Estimate"
    else
      "Active Estimate"
    end
  end

  def nice_ceiling(raw_value, step_candidates)
    step = step_candidates.find { |candidate| (raw_value / candidate) <= 8.0 } || step_candidates.last
    ((raw_value / step).ceil * step).round(2)
  end

  def build_axis_ticks(max_value, segments)
    step = max_value.to_f / segments
    (0..segments).map do |idx|
      val = (idx * step).round(2)
      label = val == val.to_i ? val.to_i.to_s : format("%.1f", val)
      { value: val, label: label }
    end
  end

  def build_zone_polygons(geometry)
    max_al = geometry[:max_al2o3]
    max_si = geometry[:max_sio2]

    wedges = [
      { key: :crazing_high_silica, min_slope: 10.0, max_slope: nil },
      { key: :satin_gloss,         min_slope: 6.0,  max_slope: 10.0 },
      { key: :matte,               min_slope: 3.5,  max_slope: 6.0 },
      { key: :unfused_refractory,  min_slope: 0.0,  max_slope: 3.5 }
    ].map do |spec|
      meta = STULL_ZONES.fetch(spec[:key])
      data_pts = stull_wedge_vertices(
        min_slope: spec[:min_slope],
        max_slope: spec[:max_slope],
        max_al: max_al,
        max_si: max_si
      )
      svg_pts = data_pts.map { |al, si| "#{stull_x(al, geometry)},#{stull_y(si, geometry)}" }.join(" ")
      label_al, label_si = zone_label_anchor(spec[:key], data_pts, max_al, max_si)

      meta.merge(
        points: svg_pts,
        label_x: stull_x(label_al, geometry),
        label_y: stull_y(label_si, geometry)
      )
    end

    uf_al = [ UNDERFIRED_MAX_AL2O3, max_al ].min
    uf_si = [ UNDERFIRED_MAX_SIO2, max_si ].min
    uf_meta = STULL_ZONES.fetch(:underfired_high_flux)
    uf_pts = [
      [ 0.0, 0.0 ],
      [ 0.0, uf_si ],
      [ uf_al, uf_si ],
      [ uf_al, 0.0 ]
    ].map { |al, si| "#{stull_x(al, geometry)},#{stull_y(si, geometry)}" }.join(" ")

    wedges << uf_meta.merge(
      points: uf_pts,
      label_x: stull_x(uf_al * 0.5, geometry),
      label_y: stull_y(uf_si * 0.48, geometry),
      dashed_border: true
    )

    wedges
  end

  def stull_wedge_vertices(min_slope:, max_slope:, max_al:, max_si:)
    p_top = ray_box_exit(max_slope, max_al, max_si)
    p_bot = ray_box_exit(min_slope, max_al, max_si)

    verts = [ [ 0.0, 0.0 ], p_top ]
    if (p_top[1] - max_si).abs < 1e-6 && (p_bot[0] - max_al).abs < 1e-6 && p_bot[1] < max_si - 1e-6
      verts << [ max_al, max_si ]
    end
    verts << p_bot
    verts
  end

  def ray_box_exit(slope, max_al, max_si)
    return [ 0.0, max_si ] if slope.nil?
    return [ max_al, 0.0 ] if slope <= 0.0

    if slope * max_al >= max_si
      [ (max_si / slope).round(4), max_si ]
    else
      [ max_al, (slope * max_al).round(4) ]
    end
  end

  def zone_label_anchor(zone_key, data_pts, max_al, max_si)
    outer_pts = data_pts[1..] || data_pts
    avg_al = outer_pts.sum { |pt| pt[0] } / outer_pts.size.to_f
    avg_si = outer_pts.sum { |pt| pt[1] } / outer_pts.size.to_f

    case zone_key
    when :crazing_high_silica
      [ (avg_al * 0.55).clamp(max_al * 0.08, max_al * 0.45), (max_si * 0.82) ]
    when :satin_gloss
      [ (avg_al * 0.72).clamp(max_al * 0.25, max_al * 0.85), (avg_si * 0.74).clamp(max_si * 0.25, max_si * 0.90) ]
    when :matte
      [ (avg_al * 0.74).clamp(max_al * 0.35, max_al * 0.85), (avg_si * 0.72).clamp(max_si * 0.20, max_si * 0.85) ]
    when :unfused_refractory
      [ (max_al * 0.70), (avg_si * 0.45).clamp(max_si * 0.10, max_si * 0.40) ]
    else
      [ avg_al * 0.6, avg_si * 0.6 ]
    end
  end

  def build_ratio_guides(geometry)
    max_al = geometry[:max_al2o3]
    max_si = geometry[:max_sio2]

    [
      { ratio: 3.5, label: "3.5:1" },
      { ratio: 6.0, label: "6:1" },
      { ratio: 10.0, label: "10:1" }
    ].map do |spec|
      exit_al, exit_si = ray_box_exit(spec[:ratio], max_al, max_si)
      {
        label: spec[:label],
        x1: stull_x(0.0, geometry),
        y1: stull_y(0.0, geometry),
        x2: stull_x(exit_al, geometry),
        y2: stull_y(exit_si, geometry),
        label_x: stull_x(exit_al * 0.90, geometry),
        label_y: stull_y(exit_si * 0.92, geometry)
      }
    end
  end
end
