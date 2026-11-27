# frozen_string_literal: true

require "test_helper"

module Ingestion
  class MineralOccurrenceSeederTest < ActiveSupport::TestCase
    setup do
      MineralOccurrence.delete_all
    end

    test "seeds all 25 curated PNW and Western NA hard-rock ceramic mineral occurrences cleanly" do
      result = Ingestion::MineralOccurrenceSeeder.call

      assert_equal 25, result.imported
      assert_equal 25, result.created
      assert_equal 0, result.updated
      assert_equal 0, result.skipped
      assert_empty result.errors
      assert_equal 25, MineralOccurrence.count

      all_terms = MineralOccurrence.all.flat_map(&:all_terms).uniq
      %w[
        basalt andesite talc soapstone olivine chromite magnesite dolomite
        feldspar wollastonite kaolin quartzite pyrolusite pumice spodumene
        lepidolite borax colemanite barite fluorite pyrite chalcopyrite
      ].each do |expected_term|
        assert_includes all_terms, expected_term, "Expected seeded atlas to include #{expected_term}"
      end

      # Verify PostGIS proximity queries work around Tacoma and Spokane quick sites
      near_tacoma = MineralOccurrence.within_radius(47.2529, -122.4443, 100_000).ordered_by_distance(47.2529, -122.4443)
      assert_operator near_tacoma.count, :>=, 4
      assert_equal "Enumclaw Cascade Andesite Quarry", near_tacoma.first.name

      near_spokane = MineralOccurrence.within_radius(47.5580, -117.0780, 50_000).ordered_by_distance(47.5580, -117.0780)
      assert_operator near_spokane.count, :>=, 2
      assert near_spokane.any? { |occ| occ.ceramic_highlights.include?("kaolin") }
    end

    test "is strictly idempotent on repeated runs" do
      first = Ingestion::MineralOccurrenceSeeder.call
      assert_equal 25, first.created
      assert_equal 0, first.updated

      second = Ingestion::MineralOccurrenceSeeder.call
      assert_equal 25, second.imported
      assert_equal 0, second.created
      assert_equal 25, second.updated
      assert_equal 0, second.skipped
      assert_equal 25, MineralOccurrence.count
    end

    test "skips invalid CSV rows gracefully while persisting valid rows" do
      csv = StringIO.new(<<~CSV)
        source,external_id,name,latitude,longitude,deposit_type,commodities,minerals,ceramic_role
        custom_atlas,CUS-1,Valid Pegmatite,47.50,-121.50,Pegmatite,Feldspar;Lithium,Spodumene;Microcline,Li-K flux
        custom_atlas,CUS-2,,47.50,-121.50,Pegmatite,Feldspar,Albite,Missing name
        custom_atlas,CUS-3,Bad Coords,99.99,-121.50,Quarry,Basalt,Augite,Out of bounds
      CSV

      result = Ingestion::MineralOccurrenceSeeder.call(csv)

      assert_equal 1, result.imported
      assert_equal 1, result.created
      assert_equal 2, result.skipped
      assert_equal 2, result.errors.size
      assert_equal 1, MineralOccurrence.by_source("custom_atlas").count
      occ = MineralOccurrence.find_by!(source: "custom_atlas", external_id: "CUS-1")
      assert_equal [ "Feldspar", "Lithium" ], occ.commodities
      assert_equal [ "Spodumene", "Microcline" ], occ.minerals
      assert_equal "Li-K flux", occ.raw_metadata["ceramic_role"]
    end
  end
end
