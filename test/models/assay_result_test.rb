# frozen_string_literal: true

require "test_helper"

class AssayResultTest < ActiveSupport::TestCase
  setup do
    @sample = UserSample.create!(title: "Glacial Silt")
  end

  test "source_type enum and JSONB defaults match schema contract" do
    assert_equal(
      { "spatial_heuristic_estimate" => 0, "verified_lab_xrf" => 1, "verified_lab_icpms" => 2 },
      AssayResult.source_types
    )

    result = @sample.assay_results.create!(
      oxides: { "SiO2" => 58.4, "Al2O3" => 17.2 },
      oxide_ranges: { "SiO2" => { "min" => 55.0, "max" => 61.0 } },
      umf_formula: { "fluxes" => { "CaO" => 0.45 }, "alumina" => 0.35, "silica" => 2.8 },
      confidence_score: 0.815,
      reasoning_log: [ "Matched Vashon glacial drift", "Adjusted Fe2O3 for red fired color" ]
    )
    result.reload

    assert result.spatial_heuristic_estimate?
    assert_equal BigDecimal("0.815"), result.confidence_score
    assert_equal 2, result.reasoning_log.length
    assert_equal 58.4, result.oxides["SiO2"]
  end

  test "validates confidence_score range" do
    bad = @sample.assay_results.new(confidence_score: 1.5)
    assert_not bad.valid?
    assert_includes bad.errors[:confidence_score], "must be less than or equal to 1"
  end
end
