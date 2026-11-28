# frozen_string_literal: true

require "test_helper"

class BlendsHelperTest < ActionView::TestCase
  include BlendsHelper

  test "simplex_svg_coordinates places 100/0/0 at top apex, 0/100/0 at bottom-left, 0/0/100 at bottom-right, and 33.3/33.3/33.3 at centroid" do
    top = simplex_svg_coordinates(100, 0, 0, width: 460, height: 400, padding: 48)
    bottom_left = simplex_svg_coordinates(0, 100, 0, width: 460, height: 400, padding: 48)
    bottom_right = simplex_svg_coordinates(0, 0, 100, width: 460, height: 400, padding: 48)
    centroid = simplex_svg_coordinates(33.3, 33.3, 33.3, width: 460, height: 400, padding: 48)

    # Top apex centered horizontally and above bottom vertices
    assert_in_delta 230.0, top[:x], 0.05
    assert_operator top[:y], :<, bottom_left[:y]

    # Bottom vertices share equal y and flank the center symmetrically
    assert_in_delta bottom_left[:y], bottom_right[:y], 0.01
    assert_operator bottom_left[:x], :<, top[:x]
    assert_operator bottom_right[:x], :>, top[:x]
    assert_in_delta(top[:x] - bottom_left[:x], bottom_right[:x] - top[:x], 0.05)

    # Equilateral triangle check: all 3 side lengths match
    side_ab = Math.hypot(top[:x] - bottom_left[:x], top[:y] - bottom_left[:y])
    side_bc = Math.hypot(bottom_right[:x] - bottom_left[:x], bottom_right[:y] - bottom_left[:y])
    side_ac = Math.hypot(top[:x] - bottom_right[:x], top[:y] - bottom_right[:y])
    assert_in_delta side_bc, side_ab, 0.1
    assert_in_delta side_bc, side_ac, 0.1

    # Centroid sits at the exact arithmetic mean of the 3 vertices
    expected_cx = (top[:x] + bottom_left[:x] + bottom_right[:x]) / 3.0
    expected_cy = (top[:y] + bottom_left[:y] + bottom_right[:y]) / 3.0
    assert_in_delta expected_cx, centroid[:x], 0.05
    assert_in_delta expected_cy, centroid[:y], 0.05
  end

  test "simplex_grid_lines generates 12 ternary tick lines at 20, 40, 60, and 80 percent across all 3 axes" do
    lines = simplex_grid_lines(width: 460, height: 400, padding: 48)

    assert_equal 12, lines.size
    assert_equal [ :a, :b, :c ], lines.map { |l| l[:axis] }.uniq.sort
    assert_equal [ 20, 40, 60, 80 ], lines.select { |l| l[:axis] == :a }.map { |l| l[:percent] }

    # Constant-A lines are horizontal (parallel to bottom B-C edge)
    lines.select { |l| l[:axis] == :a }.each do |line|
      assert_in_delta line[:y1], line[:y2], 0.01
      assert_operator line[:x2], :>, line[:x1]
    end
  end

  test "stull_zone_svg_palette maps all 5 BlendRecipeBuilder Stull zones to DCI Tailor studio SVG colors" do
    expected_fills = {
      "Gloss" => "#1E4E79",
      "Matte" => "#2F6F5E",
      "Crazing / High-Silica" => "#D97706",
      "Unfused / Refractory" => "#78716C",
      "Underfired / High-Flux" => "#C2410C"
    }

    Chemistry::BlendRecipeBuilder::STULL_ZONES.each do |zone|
      palette = stull_zone_svg_palette(zone)
      assert_equal expected_fills.fetch(zone), palette[:fill]
      assert palette[:stroke].present?
      assert_equal zone, palette[:label]
    end
  end

  test "Media::QrSvgGenerator renders standalone inline SVG for valid URLs and empty string for blank inputs" do
    svg = Media::QrSvgGenerator.call("https://example.com/samples/42")

    assert svg.html_safe?
    assert_includes svg, "<svg"
    assert_includes svg, "viewBox="
    assert_includes svg, "<path"

    assert_equal "", Media::QrSvgGenerator.call("")
    assert_equal "", Media::QrSvgGenerator.call(nil)
  end
end
