# frozen_string_literal: true

module BlendsHelper
  STULL_ZONE_SVG_PALETTES = {
    "Gloss" => {
      fill: "#1E4E79",
      stroke: "#133453",
      label: "Gloss",
      badge_classes: "bg-[#1E4E79]/12 text-[#1E4E79] border-[#1E4E79]/25"
    }.freeze,
    "Matte" => {
      fill: "#2F6F5E",
      stroke: "#1E4B3F",
      label: "Matte",
      badge_classes: "bg-emerald-900/10 text-emerald-900 border-emerald-800/25"
    }.freeze,
    "Crazing / High-Silica" => {
      fill: "#D97706",
      stroke: "#92400E",
      label: "Crazing / High-Silica",
      badge_classes: "bg-amber-100 text-amber-950 border-amber-300"
    }.freeze,
    "Unfused / Refractory" => {
      fill: "#78716C",
      stroke: "#44403C",
      label: "Unfused / Refractory",
      badge_classes: "bg-stone-200 text-stone-800 border-stone-300"
    }.freeze,
    "Underfired / High-Flux" => {
      fill: "#C2410C",
      stroke: "#7C2D12",
      label: "Underfired / High-Flux",
      badge_classes: "bg-orange-100 text-[#963B1D] border-orange-300"
    }.freeze
  }.freeze

  DEFAULT_STULL_SVG_PALETTE = STULL_ZONE_SVG_PALETTES.fetch("Unfused / Refractory")

  # Computes equilateral triangle bounds inside the SVG canvas with Material A
  # at the top apex, Material B at the bottom-left vertex, and Material C at the
  # bottom-right vertex.
  def simplex_geometry(width: 460, height: 400, padding: 48)
    avail_w = [ width.to_f - (2.0 * padding.to_f), 10.0 ].max
    avail_h = [ height.to_f - (2.0 * padding.to_f), 10.0 ].max
    sqrt3_half = Math.sqrt(3.0) / 2.0

    side = [ avail_w, avail_h / sqrt3_half ].min
    tri_height = side * sqrt3_half
    left_x = (width.to_f - side) / 2.0
    right_x = left_x + side
    top_y = (height.to_f - tri_height) / 2.0
    bottom_y = top_y + tri_height

    {
      width: width.to_f,
      height: height.to_f,
      padding: padding.to_f,
      side: side,
      tri_height: tri_height,
      left_x: left_x,
      right_x: right_x,
      top_y: top_y,
      bottom_y: bottom_y
    }
  end

  # Converts ternary percentages (pct_a, pct_b, pct_c) into 2D SVG { x:, y: }
  # coordinates with Material A (100% A) at top apex, Material B (100% B) at
  # bottom-left vertex, and Material C (100% C) at bottom-right vertex.
  def simplex_svg_coordinates(pct_a, pct_b, pct_c, width: 460, height: 400, padding: 48)
    geom = simplex_geometry(width: width, height: height, padding: padding)

    raw_a = [ pct_a.to_f, 0.0 ].max
    raw_b = [ pct_b.to_f, 0.0 ].max
    raw_c = [ pct_c.to_f, 0.0 ].max
    total = raw_a + raw_b + raw_c

    if total.positive?
      a = raw_a / total
      b = raw_b / total
      c = raw_c / total
    else
      a = 0.0
      b = 0.0
      c = 0.0
    end

    basis_sum = a + b + c
    x = (geom[:left_x] * basis_sum) + (geom[:side] * (c + (0.5 * a)))
    y = (geom[:bottom_y] * basis_sum) - (geom[:tri_height] * a)

    { x: x.round(2), y: y.round(2) }
  end

  # Generates 20%-interval ternary tick grid lines (20%, 40%, 60%, 80%) parallel
  # to all 3 edges of the equilateral simplex triangle.
  def simplex_grid_lines(width: 460, height: 400, padding: 48, steps: [ 20, 40, 60, 80 ])
    lines = []

    steps.each do |pct|
      rem = 100.0 - pct.to_f

      # Constant Material A % (horizontal lines parallel to bottom B-C edge)
      a_start = simplex_svg_coordinates(pct, rem, 0, width: width, height: height, padding: padding)
      a_end = simplex_svg_coordinates(pct, 0, rem, width: width, height: height, padding: padding)
      lines << { axis: :a, percent: pct, x1: a_start[:x], y1: a_start[:y], x2: a_end[:x], y2: a_end[:y] }

      # Constant Material B % (lines parallel to right A-C edge)
      b_start = simplex_svg_coordinates(rem, pct, 0, width: width, height: height, padding: padding)
      b_end = simplex_svg_coordinates(0, pct, rem, width: width, height: height, padding: padding)
      lines << { axis: :b, percent: pct, x1: b_start[:x], y1: b_start[:y], x2: b_end[:x], y2: b_end[:y] }

      # Constant Material C % (lines parallel to left A-B edge)
      c_start = simplex_svg_coordinates(rem, 0, pct, width: width, height: height, padding: padding)
      c_end = simplex_svg_coordinates(0, rem, pct, width: width, height: height, padding: padding)
      lines << { axis: :c, percent: pct, x1: c_start[:x], y1: c_start[:y], x2: c_end[:x], y2: c_end[:y] }
    end

    lines
  end

  # Maps Stull melt zones to high-contrast accessible SVG colors matching DCI Tailor's palette.
  def stull_zone_svg_palette(zone)
    STULL_ZONE_SVG_PALETTES.fetch(zone.to_s) do
      DEFAULT_STULL_SVG_PALETTE.merge(label: zone.to_s.presence || DEFAULT_STULL_SVG_PALETTE[:label])
    end
  end

  def simplex_candidate_batch_summary(candidate)
    named = candidate.weights.filter_map do |entry|
      pct = entry[:percentage].to_i
      next unless pct.positive?

      "#{pct}% #{truncate(entry[:sample].title.to_s, length: 24)}"
    end
    "#{candidate.batch_label} — #{named.join(' · ')}"
  end

  def simplex_candidate_umf_summary(candidate)
    si_al = candidate.si_al_ratio.present? ? format("%.2f", candidate.si_al_ratio) : "—"
    parts = [
      "SiO₂ #{format('%.2f', candidate.sio2)}",
      "Al₂O₃ #{format('%.2f', candidate.al2o3)}",
      "Si:Al #{si_al}",
      "R₂O #{format('%.2f', candidate.r2o_total)}",
      "RO #{format('%.2f', candidate.ro_total)}"
    ]
    parts << "B₂O₃ #{format('%.2f', candidate.b2o3)}" if candidate.b2o3.positive?
    parts.join(" · ")
  end

  def simplex_candidate_coe_summary(candidate)
    return "—" unless candidate.coe.present?

    risk = candidate.coe_report&.risk_label || "Unrated"
    "#{format('%.1f', candidate.coe)} ×10⁻⁷ /°C (#{risk})"
  end
end
