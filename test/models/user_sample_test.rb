# frozen_string_literal: true

require "test_helper"

class UserSampleTest < ActiveSupport::TestCase
  test "validates title presence and supports optional user and geologic_unit" do
    sample = UserSample.new
    assert_not sample.valid?
    assert_includes sample.errors[:title], "can't be blank"

    valid_sample = UserSample.create!(title: "Puget Sound Wild Clay")
    assert valid_sample.wild_clay?
    assert_nil valid_sample.user_id
    assert_nil valid_sample.geologic_unit_id
  end

  test "material_category enum maps exact integer codes" do
    assert_equal(
      { "wild_clay" => 0, "crushed_rock" => 1, "wood_ash" => 2, "other" => 3 },
      UserSample.material_categories
    )

    sample = UserSample.create!(title: "Columbia Basalt Dust", material_category: :crushed_rock)
    assert sample.crushed_rock?
  end

  test "latitude and longitude accessors build and read SRID 4326 point" do
    sample = UserSample.new(title: "Tacoma Clay")
    sample.latitude = "47.2529"
    sample.longitude = "-122.4443"
    sample.save!
    sample.reload

    assert_equal 4326, sample.location.srid
    assert_in_delta 47.2529, sample.latitude, 0.0001
    assert_in_delta(-122.4443, sample.longitude, 0.0001)
  end

  test "rejects invalid coordinate bounds" do
    sample = UserSample.new(title: "Bad Coords", latitude: 120.0, longitude: -122.4)
    assert_not sample.valid?
    assert_includes sample.errors[:latitude], "must be between -90 and 90"
  end

  test "associates with user, geologic_unit, field_observations, and assay_results" do
    user = User.create!(email: "potter@example.com", name: "Studio Potter")
    unit = GeologicUnit.create!(macrostrat_id: 5001, name: "Vashon Drift")
    sample = UserSample.create!(
      user: user,
      geologic_unit: unit,
      title: "Dash Point Seam",
      latitude: 47.3223,
      longitude: -122.4126
    )

    obs = sample.field_observations.create!(vinegar_fizz: :slight, plasticity: :high_plastic)
    assay = sample.assay_results.create!(source_type: :spatial_heuristic_estimate, confidence_score: 0.725)

    assert_equal obs, sample.latest_field_observation
    assert_equal assay, sample.latest_assay_result

    assert_difference [ "FieldObservation.count", "AssayResult.count" ], -1 do
      sample.destroy!
    end
  end
end
