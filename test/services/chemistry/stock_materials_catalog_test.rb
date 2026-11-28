# frozen_string_literal: true

require "test_helper"

module Chemistry
  class StockMaterialsCatalogTest < ActiveSupport::TestCase
    EXPECTED_KEYS = %w[
      whiting
      wollastonite
      dolomite
      talc
      ferro_frit_3134
      ferro_frit_3124
      ferro_frit_3195
      gerstley_borate
      custer_feldspar
      minspar_200
      nepheline_syenite
      spodumene
      strontium_carbonate
      zinc_oxide
      epk_kaolin
      om4_ball_clay
      silica
      red_iron_oxide
    ].freeze

    test "contains all 18 authentic ceramic studio staple materials with valid helper methods" do
      assert_equal 18, StockMaterialsCatalog.all.size
      assert_equal EXPECTED_KEYS, StockMaterialsCatalog.keys

      StockMaterialsCatalog.all.each do |material|
        assert_equal "stock:#{material.key}", material.id
        assert material.stock?
        assert_not material.persisted?
        assert material.title.present?
        assert material.notes.present?
        assert_includes %w[flux stabilizer], material.role

        assert_equal CeramicOxides::KEYS.sort, material.oxides.keys.sort
        total = material.oxides.values.sum + material.minor_oxides.values.sum
        assert_in_delta 100.0, total, 0.01, "Expected #{material.key} oxides + minors to sum to 100%, got #{total}"

        normalized = Exporters::GlazecalcMaterialSerializer.normalize_oxides(
          material.oxides,
          minor_oxides: material.minor_oxides
        )
        assert_in_delta 100.0, normalized.values.sum, 0.01, "Normalized total off for #{material.key}"

        umf = Chemistry::UmfCalculator.call(material.oxides, minor_oxides: material.minor_oxides)
        assert_kind_of Hash, umf
        assert umf.key?("flux_total")
      end
    end

    test "finds materials by plain key, symbol, or stock-prefixed id and handles unknown keys" do
      whiting = StockMaterialsCatalog.find("whiting")
      assert_not_nil whiting
      assert_equal "Whiting (CaCO3)", whiting.title
      assert_equal whiting, StockMaterialsCatalog.find(:whiting)
      assert_equal whiting, StockMaterialsCatalog.find("stock:whiting")
      assert_equal whiting, StockMaterialsCatalog.find("  STOCK:Whiting ")

      frit = StockMaterialsCatalog.find("stock:ferro_frit_3134")
      assert_equal "ferro_frit_3134", frit.key
      assert_in_delta 23.1, frit.minor_oxides["B2O3"], 0.1

      assert_nil StockMaterialsCatalog.find("unknown_material")
      assert_nil StockMaterialsCatalog.find("")
      assert_nil StockMaterialsCatalog.find(nil)
    end

    test "groups materials cleanly into fluxes and stabilizers with authentic key oxides" do
      grouped = StockMaterialsCatalog.grouped_by_role
      assert_equal %w[flux stabilizer], grouped.keys
      assert_equal 14, grouped["flux"].size
      assert_equal 4, grouped["stabilizer"].size

      assert_operator StockMaterialsCatalog.find("ferro_frit_3134").minor_oxides["B2O3"], :>, 20.0
      assert_operator StockMaterialsCatalog.find("ferro_frit_3124").minor_oxides["B2O3"], :>, 10.0
      assert_operator StockMaterialsCatalog.find("ferro_frit_3195").minor_oxides["B2O3"], :>, 20.0
      assert_operator StockMaterialsCatalog.find("gerstley_borate").minor_oxides["B2O3"], :>, 25.0
      assert_operator StockMaterialsCatalog.find("spodumene").minor_oxides["Li2O"], :>, 6.0
      assert_operator StockMaterialsCatalog.find("strontium_carbonate").minor_oxides["SrO"], :>, 65.0
      assert_operator StockMaterialsCatalog.find("zinc_oxide").minor_oxides["ZnO"], :>, 95.0
      assert_operator StockMaterialsCatalog.find("epk_kaolin").oxides["Al2O3"], :>, 35.0
      assert_operator StockMaterialsCatalog.find("silica").oxides["SiO2"], :>, 99.0
      assert_operator StockMaterialsCatalog.find("red_iron_oxide").oxides["Fe2O3"], :>, 90.0

      assert_includes StockMaterialsCatalog.find("ferro_frit_3134").quick_tags.map { |t| t[:label] }, "B₂O₃"
      assert_includes StockMaterialsCatalog.find("spodumene").quick_tags.map { |t| t[:label] }, "Li₂O"
    end
  end
end
