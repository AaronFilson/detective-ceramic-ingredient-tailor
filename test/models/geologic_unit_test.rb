# frozen_string_literal: true

require "test_helper"

class GeologicUnitTest < ActiveSupport::TestCase
  test "validates macrostrat_id presence and uniqueness" do
    unit = GeologicUnit.new(name: "Vashon Drift")
    assert_not unit.valid?
    assert_includes unit.errors[:macrostrat_id], "can't be blank"

    GeologicUnit.create!(macrostrat_id: 9001, name: "Vashon Drift")
    dup = GeologicUnit.new(macrostrat_id: 9001, name: "Duplicate")
    assert_not dup.valid?
    assert_includes dup.errors[:macrostrat_id], "has already been taken"
  end

  test "stores both Polygon and MultiPolygon SRID 4326 GeoJSON boundaries" do
    factory = RGeo::Cartesian.preferred_factory(srid: 4326)

    polygon_geojson = {
      "type" => "Polygon",
      "coordinates" => [[[-122.5, 47.2], [-122.4, 47.2], [-122.4, 47.3], [-122.5, 47.3], [-122.5, 47.2]]]
    }
    poly_unit = GeologicUnit.create!(
      macrostrat_id: 9002,
      name: "Puget Glacial Unit",
      boundary: RGeo::GeoJSON.decode(polygon_geojson, geo_factory: factory)
    )
    poly_unit.reload
    assert_equal 4326, poly_unit.boundary.srid
    assert_equal "Polygon", poly_unit.boundary.geometry_type.type_name

    multipolygon_geojson = {
      "type" => "MultiPolygon",
      "coordinates" => [
        [[[-122.6, 47.1], [-122.5, 47.1], [-122.5, 47.2], [-122.6, 47.2], [-122.6, 47.1]]],
        [[[-122.3, 47.3], [-122.2, 47.3], [-122.2, 47.4], [-122.3, 47.4], [-122.3, 47.3]]]
      ]
    }
    multi_unit = GeologicUnit.create!(
      macrostrat_id: 9003,
      name: "Cascade Volcanic Complex",
      boundary: RGeo::GeoJSON.decode(multipolygon_geojson, geo_factory: factory)
    )
    multi_unit.reload
    assert_equal 4326, multi_unit.boundary.srid
    assert_equal "MultiPolygon", multi_unit.boundary.geometry_type.type_name
  end

  test "lithology_terms extracts downcased terms across Macrostrat JSONB formats" do
    unit_a = GeologicUnit.new(
      macrostrat_id: 9010,
      lithology: { "lith" => "Major:{Basalt, Andesite}, Minor:{Tuff}" }
    )
    assert_equal %w[basalt andesite tuff], unit_a.lithology_terms

    unit_b = GeologicUnit.new(
      macrostrat_id: 9011,
      lithology: {
        "liths" => [
          { "lith_id" => 12, "name" => "Glacial Till", "type" => "Unconsolidated", "prop" => 0.7 },
          { "lith_id" => 14, "name" => "Clay", "type" => "Siliciclastic", "prop" => 0.3 }
        ]
      }
    )
    assert_equal ["glacial till", "unconsolidated", "clay", "siliciclastic"], unit_b.lithology_terms

    unit_c = GeologicUnit.new(macrostrat_id: 9012, lithology: {})
    assert_equal [], unit_c.lithology_terms
  end

  test "associates with user_samples" do
    unit = GeologicUnit.create!(macrostrat_id: 9020, name: "Lawton Clay")
    sample = UserSample.create!(title: "Bluff clay", geologic_unit: unit)
    assert_includes unit.user_samples, sample
  end
end
