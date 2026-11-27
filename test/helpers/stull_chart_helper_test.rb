# frozen_string_literal: true

require "test_helper"

class StullChartHelperTest < ActionView::TestCase
  include StullChartHelper

  test "stull_zone_for classifies all five ceramic Stull zones accurately" do
    unfused = stull_zone_for(al2o3: 0.90, sio2: 2.20)
    assert_equal :unfused_refractory, unfused[:zone]
    assert_equal "Unfused / Refractory", unfused[:label]
    assert_predicate unfused[:description], :present?
    assert_predicate unfused[:badge_classes], :present?

    matte = stull_zone_for(al2o3: 0.52, sio2: 2.60)
    assert_equal :matte, matte[:zone]
    assert_equal "Matte", matte[:label]

    gloss = stull_zone_for(al2o3: 0.40, sio2: 3.20)
    assert_equal :satin_gloss, gloss[:zone]
    assert_equal "Satin / Gloss", gloss[:label]

    crazing = stull_zone_for(al2o3: 0.25, sio2: 3.80)
    assert_equal :crazing_high_silica, crazing[:zone]
    assert_equal "Crazing / High-Silica", crazing[:label]

    zero_al_high_si = stull_zone_for(al2o3: 0.0, sio2: 4.50)
    assert_equal :crazing_high_silica, zero_al_high_si[:zone]

    underfired = stull_zone_for(al2o3: 0.04, sio2: 0.35)
    assert_equal :underfired_high_flux, underfired[:zone]
    assert_equal "Underfired / High-Flux", underfired[:label]
  end

  test "stull_axis_bounds keeps standard glaze window for normal UMF values and maps inside plot frame" do
    point = stull_extract_point(
      {
        "intermediates" => { "Al2O3" => 0.42 },
        "glass_formers" => { "SiO2" => 3.50 },
        "si_al_ratio" => 8.33
      }
    )

    bounds = stull_axis_bounds([ point ])
    assert_in_delta 1.2, bounds[:max_al2o3], 0.001
    assert_in_delta 10.0, bounds[:max_sio2], 0.001
    assert_not bounds[:expanded]

    geom = stull_plot_geometry(max_al2o3: bounds[:max_al2o3], max_sio2: bounds[:max_sio2])
    x = stull_x(point[:al2o3], geom)
    y = stull_y(point[:sio2], geom)

    assert_operator x, :>, geom[:left]
    assert_operator x, :<, geom[:right]
    assert_operator y, :>, geom[:top]
    assert_operator y, :<, geom[:bottom]

    # Higher SiO2 must plot higher up (smaller SVG Y coordinate)
    assert_operator stull_y(9.0, geom), :<, stull_y(1.0, geom)
  end

  test "stull_axis_bounds expands smoothly for high-silica and refractory raw clays" do
    high_silica_clay = stull_extract_point(
      {
        "intermediates" => { "Al2O3" => 2.15 },
        "glass_formers" => { "SiO2" => 16.40 },
        "si_al_ratio" => 7.63
      }
    )

    bounds = stull_axis_bounds([ high_silica_clay ])
    assert bounds[:expanded]
    assert_operator bounds[:max_al2o3], :>, 2.15
    assert_operator bounds[:max_sio2], :>, 16.40

    chart = stull_chart_model(assay_result: {
      "intermediates" => { "Al2O3" => 2.15 },
      "glass_formers" => { "SiO2" => 16.40 },
      "si_al_ratio" => 7.63
    })

    geom = chart[:geometry]
    assert_equal 5, chart[:zones].size
    assert_operator chart[:active_point][:cx], :>, geom[:left]
    assert_operator chart[:active_point][:cx], :<, geom[:right]
    assert_operator chart[:active_point][:cy], :>, geom[:top]
    assert_operator chart[:active_point][:cy], :<, geom[:bottom]
  end

  test "stull_shift_vector and stull_chart_model compute Heuristic to Verified Lab shift accurately" do
    sample = UserSample.create!(
      title: "Shift Vector Clay",
      material_category: :wild_clay,
      latitude: 47.2529,
      longitude: -122.4443
    )

    heuristic = sample.assay_results.create!(
      source_type: :spatial_heuristic_estimate,
      oxides: { "SiO2" => 60.0, "Al2O3" => 20.0, "CaO" => 10.0, "LOI" => 10.0 },
      umf_formula: {
        "intermediates" => { "Al2O3" => 0.55 },
        "glass_formers" => { "SiO2" => 2.75 },
        "si_al_ratio" => 5.0
      },
      confidence_score: 0.62
    )

    verified_lab = sample.assay_results.create!(
      source_type: :verified_lab_xrf,
      lab_name: "WSU GeoAnalytical Lab",
      oxides: { "SiO2" => 64.0, "Al2O3" => 16.0, "CaO" => 12.0, "LOI" => 8.0 },
      umf_formula: {
        "intermediates" => { "Al2O3" => 0.42 },
        "glass_formers" => { "SiO2" => 3.36 },
        "si_al_ratio" => 8.0
      },
      confidence_score: 0.98
    )

    chart = stull_chart_model(
      assay_result: verified_lab,
      heuristic_assay: heuristic,
      verified_lab_assay: verified_lab
    )

    assert_not_nil chart
    assert_equal "Verified Lab", chart[:active_point][:label]
    assert_equal :satin_gloss, chart[:active_point][:zone][:zone]
    assert_equal "Spatial Heuristic", chart[:comparison_point][:label]
    assert_equal :matte, chart[:comparison_point][:zone][:zone]

    shift = chart[:shift_vector]
    assert_not_nil shift
    assert_in_delta(-0.13, shift[:delta_al2o3], 0.001)
    assert_in_delta 0.61, shift[:delta_sio2], 0.001
    assert_in_delta 3.0, shift[:delta_si_al], 0.01
    assert_in_delta Math.hypot(-0.13, 0.61), shift[:distance], 0.001
    assert shift[:zone_changed]
    assert_equal chart[:comparison_point][:cx], shift[:x1]
    assert_equal chart[:comparison_point][:cy], shift[:y1]
    assert_equal chart[:active_point][:cx], shift[:x2]
    assert_equal chart[:active_point][:cy], shift[:y2]

    tooltip = stull_point_tooltip(chart[:active_point])
    assert_includes tooltip, "Al2O3: 0.420"
    assert_includes tooltip, "SiO2: 3.360"
    assert_includes tooltip, "Satin / Gloss"
  end
end
