# frozen_string_literal: true

require "test_helper"

class ReferenceAssayTest < ActiveSupport::TestCase
  test "validates source presence and source+external_id uniqueness" do
    assay = ReferenceAssay.new(external_id: "X-1")
    assert_not assay.valid?
    assert_includes assay.errors[:source], "can't be blank"

    ReferenceAssay.create!(source: "usgs_ngdb", external_id: "X-1", rock_type: "basalt")

    dup = ReferenceAssay.new(source: "usgs_ngdb", external_id: "X-1")
    assert_not dup.valid?
    assert_includes dup.errors[:external_id], "has already been taken"

    different_source = ReferenceAssay.new(source: "earthchem", external_id: "X-1")
    assert different_source.valid?
  end

  test "latitude and longitude helpers build SRID 4326 spherical point" do
    assay = ReferenceAssay.create!(
      source: "usgs_ngdb",
      external_id: "GEO-1",
      rock_type: "glacial_clay",
      latitude: 47.2529,
      longitude: -122.4443,
      oxides: { "SiO2" => 58.4, "Al2O3" => 17.2 }
    )
    assay.reload

    assert_equal 4326, assay.location.srid
    assert_in_delta 47.2529, assay.latitude, 0.0001
    assert_in_delta(-122.4443, assay.longitude, 0.0001)
    assert_in_delta 58.4, assay.oxide_value("SiO2"), 0.001
  end

  test "spatial scopes filter by radius and order by distance in meters" do
    tacoma_lat = 47.2529
    tacoma_lng = -122.4443

    near = ReferenceAssay.create!(
      source: "usgs_ngdb",
      external_id: "NEAR-1",
      rock_type: "glacial_clay",
      latitude: 47.2740,
      longitude: -122.4680
    )
    mid = ReferenceAssay.create!(
      source: "usgs_ngdb",
      external_id: "MID-1",
      rock_type: "marine_clay",
      latitude: 47.5750,
      longitude: -122.4050
    )
    far = ReferenceAssay.create!(
      source: "usgs_ngdb",
      external_id: "FAR-1",
      rock_type: "kaolin_clay",
      latitude: 32.9815,
      longitude: -82.8101
    )

    within_50km = ReferenceAssay
      .within_radius(tacoma_lat, tacoma_lng, 50_000)
      .ordered_by_distance(tacoma_lat, tacoma_lng)
      .to_a

    assert_equal [near, mid], within_50km
    assert_not_includes within_50km, far
  end
end
