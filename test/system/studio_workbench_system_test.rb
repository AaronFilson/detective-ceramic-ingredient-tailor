# frozen_string_literal: true

require "application_system_test_case"
require "tempfile"

class StudioWorkbenchSystemTest < ApplicationSystemTestCase
  setup do
    StudioSetting.delete_all
    stub_external_geochemical_apis

    @geo_factory = RGeo::Cartesian.preferred_factory(srid: 4326)
    ring = @geo_factory.linear_ring([
      @geo_factory.point(-122.6, 47.1),
      @geo_factory.point(-122.2, 47.1),
      @geo_factory.point(-122.2, 47.4),
      @geo_factory.point(-122.6, 47.4),
      @geo_factory.point(-122.6, 47.1)
    ])
    @tacoma_unit = GeologicUnit.create!(
      macrostrat_id: 992_001,
      name: "Vashon Glacial Drift",
      strat_name: "Fraser Glaciation",
      age: "Pleistocene",
      lithology: {
        "raw" => "Major:{glacial till, clay}, Minor:{silt, gravel}",
        "color" => "#7BA05B"
      },
      boundary: @geo_factory.polygon(ring)
    )

    3.times do |i|
      ReferenceAssay.create!(
        source: "test_usgs",
        external_id: "SYS-TACOMA-#{i}",
        rock_type: "glacial_clay",
        latitude: 47.25 + (i * 0.01),
        longitude: -122.44 - (i * 0.01),
        oxides: {
          "SiO2" => 59.0 + i * 0.3,
          "Al2O3" => 17.0,
          "Fe2O3" => 6.2,
          "CaO" => 3.0,
          "MgO" => 2.5,
          "Na2O" => 2.4,
          "K2O" => 2.2,
          "TiO2" => 0.85,
          "P2O5" => 0.18,
          "MnO" => 0.12,
          "LOI" => 6.55 - i * 0.3
        },
        raw_metadata: { "locality" => "Tacoma System Site #{i}" }
      )
    end
  end

  test "first-time visitor completes DCI Tailor setup wizard and lands on clean workbench" do
    visit root_path

    assert_text "DCI Tailor"
    assert_selector "#setup_wizard_modal"
    assert_selector "#regional_sync_card", count: 1
    assert_selector "#wizard_regional_sync_card", count: 1, visible: :all
    assert_text "Welcome to DCI Tailor"

    within "#setup_wizard_modal" do
      fill_in "Studio or Potter Name (Optional)", with: "Cascade Wild Clay Studio"
      if js_driver?
        click_button "Next Step →"
        click_button "Next Step →"
      end
      select "Cone 10 — High-Fire Reduction / Porcelain (~1305°C)", from: "Primary Kiln Firing Cone"
      if js_driver?
        click_button "Next Step →"
      end
      uncheck "create_starter_sample"
      click_button "Save Studio Setup & Start"
    end

    assert_no_selector "#setup_wizard_modal"
    assert_text "Cascade Wild Clay Studio"
    assert_text "Sample Provenance & Geologic Unit"
    assert StudioSetting.current.onboarding_completed?
    assert_equal "10", StudioSetting.current.default_fired_cone
  end

  test "end-to-end sample photo EXIF GPS auto-pin, Step 2 tile photos, and Step 3 live assay display" do
    StudioSetting.current.complete_onboarding!(
      studio_name: "Puget Sound Clayworks",
      home_region_label: "US Southwest",
      default_lat: 35.6870,
      default_lng: -105.9378,
      default_fired_cone: "6"
    )

    with_temp_photo("outcrop_exif.jpg", build_jpeg_with_gps(lat: 47.2529, lng: -122.4443)) do |outcrop_path|
      with_temp_photo("raw_tile.jpg", minimal_jpeg_bytes) do |raw_tile_path|
        with_temp_photo("fired_tile.jpg", minimal_jpeg_bytes) do |fired_tile_path|
          visit new_sample_path

          assert_no_selector "#setup_wizard_modal"
          fill_in "Sample Title", with: "Commencement Bay Outcrop Clay"
          select "Wild Clay", from: "Material Category"
          attach_file "Outcrop / Dig-Site Photos", outcrop_path
          assert_checked_field "auto_pin_from_photo"
          click_button "Save & Run Baseline Assay"

          assert_text "Pinned coordinates (47.2529, -122.4443) automatically from outcrop photo EXIF GPS."
          assert_text "Vashon Glacial Drift"
          assert_selector "#sample_photo_gallery [data-outcrop-photo-grid] img", count: 1

          sample = UserSample.order(:id).last
          assert_in_delta 47.2529, sample.latitude, 0.0001
          assert_in_delta(-122.4443, sample.longitude, 0.0001)
          assert sample.outcrop_photos.attached?

          # Step 2: Log vigorous vinegar fizz + raw & fired test-tile photos
          within "#field_observation_form" do
            if js_driver?
              find("label", text: "Vigorous").click
            else
              choose "field_observation_vinegar_fizz_vigorous"
            end
            select "Cone 6 (1222 °C — Mid-Fire Stoneware)", from: "Fired Cone"
            fill_in "Fired Color", with: "Terracotta red"
            if js_driver?
              find("label", text: "Vitrified / Tight").click
            else
              choose "field_observation_melt_state_vitrified_tight"
            end
            attach_file "Raw Test-Tile Photo", raw_tile_path
            attach_file "Fired Test-Tile Photo", fired_tile_path
            click_button "Apply Observations & Recalculate Assay"
          end

          # Verify Step 3 live oxide table, UMF, hazard screening & reasoning trail
          within "#assay_estimate_panel" do
            assert_selector "tr[data-oxide-row='SiO2']"
            assert_selector "tr[data-oxide-row='CaO']"
            assert_text "SiO2 : Al2O3 Molar Ratio"
            assert_selector "#hazard_alerts_panel"
            assert_text "Studio Safety, Kiln & Mineralogy Screening"
            assert_selector "[data-reasoning-log]"
            assert_text(/vinegar|carbonate|caco3/i)
          end

          # Verify Step 2 diagnostic history displays mini raw & fired tile thumbnails
          within "#field_observation_history" do
            assert_text "Fizz: vigorous"
            assert_selector "[data-history-tile-photos] img", count: 2
          end

          # Verify Step 1 photo gallery updated live via Turbo Stream before any full page reload
          within "#sample_photo_gallery" do
            assert_selector "[data-outcrop-photo-grid] img", count: 1
            assert_selector "[data-tile-progression-gallery] img", count: 2
          end

          # Reload full workbench page to verify Step 1 photo gallery persists both outcrop + raw/fired progression
          visit sample_path(sample)
          within "#sample_photo_gallery" do
            assert_selector "[data-outcrop-photo-grid] img", count: 1
            assert_selector "[data-tile-progression-gallery] img", count: 2
            assert_text "Cone 6"
            assert_text "Terracotta red"
            assert_text "Vitrified tight"
          end
        end
      end
    end
  end

  test "visiting /blends renders the Local Material Glaze Recipe Builder cleanly" do
    StudioSetting.current.complete_onboarding!(studio_name: "Puget Sound Clayworks")

    clay = UserSample.create!(
      title: "Tacoma Glacial Bluff Clay",
      material_category: :wild_clay,
      latitude: 47.2529,
      longitude: -122.4443
    )
    ash = UserSample.create!(
      title: "Alder Wood Stove Ash",
      material_category: :wood_ash,
      latitude: 47.2529,
      longitude: -122.4443
    )
    SamplesController.estimate_sample(clay)
    SamplesController.estimate_sample(ash)

    visit blends_path

    assert_text "DCI Tailor"
    assert_text "Local Material Glaze Recipe Builder"
    assert_text "Tacoma Glacial Bluff Clay"
    assert_text "Alder Wood Stove Ash"
    assert_button "Calculate Optimal Glaze Blend"
  end

  test "single wild clay auto-reformulates on /blends with Studio Stock Modifiers, B2O3, and COE badge, and Step 1 renders regional sync card" do
    StudioSetting.current.complete_onboarding!(studio_name: "Puget Sound Clayworks", default_fired_cone: "6")

    clay = UserSample.create!(
      title: "Solo Wild Bluff Clay",
      material_category: :wild_clay,
      latitude: 47.2529,
      longitude: -122.4443
    )
    SamplesController.estimate_sample(clay)

    visit sample_path(clay)
    assert_selector "#regional_sync_card"
    assert_button "Hydrate Regional Atlas"

    visit blends_path
    assert_text "Solo Wild Bluff Clay"
    assert_text "Studio Stock Modifiers"
    assert_text "Whiting (CaCO3)"
    assert_text "Ferro Frit 3134"
    assert_text "Optimal Recipe"
    assert_text "COE"
    assert_text "B₂O₃"
  end

  private

  def stub_external_geochemical_apis
    stub_request(:get, %r{\Ahttps://macrostrat\.org/api/v2/geologic_units/map})
      .to_return(
        status: 200,
        body: { type: "FeatureCollection", features: [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    stub_request(:post, "https://sdmdataaccess.sc.egov.usda.gov/Tabular/post.rest")
      .to_return(
        status: 200,
        body: { Table: [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    stub_request(:get, %r{\Ahttps://rest\.isric\.org/soilgrids/v2\.0/properties/query})
      .to_return(
        status: 200,
        body: { properties: { layers: [] } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    stub_request(:get, %r{\Ahttps://mrdata\.usgs\.gov/})
      .to_return(
        status: 200,
        body: { type: "FeatureCollection", features: [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end

  def with_temp_photo(filename, bytes)
    ext = File.extname(filename)
    base = File.basename(filename, ext)
    Tempfile.create([ base, ext ], binmode: true) do |tmp|
      tmp.write(bytes)
      tmp.flush
      yield tmp.path
    end
  end

  def minimal_jpeg_bytes
    "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xFF\xD9".b
  end

  def build_jpeg_with_gps(lat:, lng:)
    lat_ref = lat >= 0 ? "N\x00\x00\x00".b : "S\x00\x00\x00".b
    lng_ref = lng >= 0 ? "E\x00\x00\x00".b : "W\x00\x00\x00".b
    lat_dms = decimal_to_dms_rationals(lat.abs)
    lng_dms = decimal_to_dms_rationals(lng.abs)

    tiff = +"II".b
    tiff << [ 42 ].pack("v")
    tiff << [ 8 ].pack("V")
    tiff << [ 1 ].pack("v")
    tiff << [ 0x8825, 4, 1, 26 ].pack("vvVV")
    tiff << [ 0 ].pack("V")
    tiff << [ 4 ].pack("v")
    tiff << [ 0x0001, 2, 2 ].pack("vvV") << lat_ref
    tiff << [ 0x0002, 5, 3, 80 ].pack("vvVV")
    tiff << [ 0x0003, 2, 2 ].pack("vvV") << lng_ref
    tiff << [ 0x0004, 5, 3, 104 ].pack("vvVV")
    tiff << [ 0 ].pack("V")
    lat_dms.each { |num, den| tiff << [ num, den ].pack("VV") }
    lng_dms.each { |num, den| tiff << [ num, den ].pack("VV") }

    app1_payload = "Exif\x00\x00".b + tiff
    "\xFF\xD8\xFF\xE1".b + [ app1_payload.bytesize + 2 ].pack("n") + app1_payload + "\xFF\xD9".b
  end

  def decimal_to_dms_rationals(decimal)
    deg = decimal.floor
    rem_min = (decimal - deg) * 60.0
    min = rem_min.floor
    sec = ((rem_min - min) * 60.0 * 10_000).round
    [ [ deg, 1 ], [ min, 1 ], [ sec, 10_000 ] ]
  end
end
