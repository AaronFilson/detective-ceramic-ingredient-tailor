# frozen_string_literal: true

require "test_helper"

class SamplesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @geo_factory = RGeo::Cartesian.preferred_factory(srid: 4326)
    ring = @geo_factory.linear_ring([
      @geo_factory.point(-122.6, 47.1),
      @geo_factory.point(-122.2, 47.1),
      @geo_factory.point(-122.2, 47.4),
      @geo_factory.point(-122.6, 47.4),
      @geo_factory.point(-122.6, 47.1)
    ])
    @tacoma_unit = GeologicUnit.create!(
      macrostrat_id: 991_001,
      name: "Vashon Glacial Drift",
      strat_name: "Fraser Glaciation",
      age: "Pleistocene",
      lithology: {
        "raw" => "Major:{glacial till, clay}, Minor:{silt, gravel}",
        "color" => "#7BA05B"
      },
      boundary: @geo_factory.polygon(ring)
    )

    # Seed nearby Tacoma reference assays so spatial baseline runs against real PostGIS points
    5.times do |i|
      ReferenceAssay.create!(
        source: "test_usgs",
        external_id: "TACOMA-TEST-#{i}",
        rock_type: "glacial_clay",
        latitude: 47.25 + (i * 0.01),
        longitude: -122.44 - (i * 0.01),
        oxides: {
          "SiO2" => 58.5 + i * 0.4,
          "Al2O3" => 17.2 - i * 0.1,
          "Fe2O3" => 6.3 + i * 0.1,
          "CaO" => 3.1 + i * 0.1,
          "MgO" => 2.5,
          "Na2O" => 2.4,
          "K2O" => 2.2,
          "TiO2" => 0.85,
          "P2O5" => 0.18,
          "MnO" => 0.12,
          "LOI" => 6.65 - i * 0.5
        },
        raw_metadata: { "locality" => "Tacoma Bluff #{i}", "formation" => "Vashon Drift" }
      )
    end
  end

  test "GET / renders split-screen studio workbench with Leaflet and map-picker bindings" do
    get root_path
    assert_response :success

    assert_includes response.body, "https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"
    assert_includes response.body, "https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"
    assert_not_includes response.body, "container mx-auto mt-28"

    assert_select "[data-controller='map-picker']"
    assert_select "[data-map-picker-target='canvas']"
    assert_select "input[type='checkbox'][data-map-picker-target='macrostratToggle']"
    assert_select "input[type='range'][data-map-picker-target='macrostratOpacity'][value='0.65']"
    assert_select "turbo-frame#geologic_unit_card"
    assert_select "button[data-action='click->map-picker#jumpToLocation']", minimum: 3
    assert_select "header a[href='/blends']", text: /Blend Builder/
    assert_includes response.body, "Tacoma WA"
    assert_includes response.body, "Mt. Rainier Cascades"
    assert_includes response.body, "Columbia Gorge Basalt"
    assert_includes response.body, "USDA SSURGO soil horizon profile populates automatically for US coordinates"
  end

  test "GET /samples/new renders blank draft sample centered on Tacoma WA" do
    get new_sample_path
    assert_response :success

    assert_select "input[name='user_sample[latitude]'][value='47.2529']"
    assert_select "input[name='user_sample[longitude]'][value='-122.4443']"
    assert_includes response.body, "Save &amp; Run Baseline Assay"
  end

  test "GET /samples/geologic_lookup renders Turbo Frame geologic_unit_card with matched unit" do
    get geologic_lookup_samples_path(lat: 47.2529, lng: -122.4443),
      headers: { "Turbo-Frame" => "geologic_unit_card" }

    assert_response :success
    assert_select "turbo-frame#geologic_unit_card" do
      assert_select "[data-geologic-unit-meta][data-geologic-unit-id='#{@tacoma_unit.id}']"
      assert_includes response.body, "Vashon Glacial Drift"
      assert_includes response.body, "Fraser Glaciation"
      assert_includes response.body, "Pleistocene"
      assert_includes response.body, "Macrostrat #991001"
      assert_includes response.body, "glacial till"
      assert_includes response.body, "Polygon"
    end
  end

  test "GET /samples/geologic_lookup renders graceful fallback when no cached unit covers coordinates" do
    stub_request(:get, "https://macrostrat.org/api/v2/geologic_units/map")
      .with(query: hash_including("lat" => "10.0", "lng" => "-150.0", "format" => "geojson"))
      .to_return(
        status: 200,
        body: { type: "FeatureCollection", features: [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    get geologic_lookup_samples_path(lat: 10.0, lng: -150.0)

    assert_response :success
    assert_select "turbo-frame#geologic_unit_card"
    assert_includes response.body, "10.0000, -150.0000"
  end

  test "POST /samples creates a UserSample, links GeologicUnit, and persists baseline AssayResult" do
    assert_difference [ "UserSample.count", "AssayResult.count" ], 1 do
      post samples_path, params: {
        user_sample: {
          title: "Commencement Bay Bluff Clay",
          material_category: "wild_clay",
          latitude: "47.2529",
          longitude: "-122.4443",
          notes: "Collected 1.5m below topsoil"
        }
      }
    end

    sample = UserSample.order(:id).last
    assert_redirected_to sample_path(sample)
    assert_equal "Commencement Bay Bluff Clay", sample.title
    assert_equal "wild_clay", sample.material_category
    assert_in_delta 47.2529, sample.latitude, 0.0001
    assert_in_delta(-122.4443, sample.longitude, 0.0001)
    assert_equal @tacoma_unit.id, sample.geologic_unit_id

    assay = sample.latest_assay_result
    assert_not_nil assay
    assert assay.spatial_heuristic_estimate?
    assert_in_delta 100.0, assay.oxides.values.sum, 0.1
    assert assay.umf_formula["si_al_ratio"].present?
    assert_not_empty assay.reasoning_log
  end

  test "POST /samples with missing title returns 422 and displays errors" do
    assert_no_difference "UserSample.count" do
      post samples_path, params: {
        user_sample: {
          title: "",
          material_category: "wild_clay",
          latitude: "47.2529",
          longitude: "-122.4443"
        }
      }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Title can&#39;t be blank"
  end

  test "GET /samples/:id renders all 3 workbench steps, oxide table, UMF readout, and export actions" do
    post samples_path, params: {
      user_sample: {
        title: "Point Defiance Clay",
        material_category: "wild_clay",
        latitude: "47.2529",
        longitude: "-122.4443"
      }
    }
    sample = UserSample.order(:id).last

    get sample_path(sample)
    assert_response :success

    # Step 2 form present for saved sample
    assert_select "form[action='#{sample_field_observations_path(sample)}'][method='post']"
    assert_select "input[name='field_observation[vinegar_fizz]'][value='vigorous']"

    # Step 3 assay panel with all canonical oxides, UMF, Stull SVG chart, reasoning log, and interop links
    assert_select "#assay_estimate_panel" do
      CeramicOxides::KEYS.each do |oxide|
        assert_select "tr[data-oxide-row='#{oxide}']"
      end
      assert_includes response.body, "SiO2 : Al2O3 Molar Ratio"
      assert_includes response.body, "RO + R2O"
      assert_includes response.body, "100.0%"
      assert_select "svg[data-stull-chart]"
      assert_select "[data-stull-active-point]"
      assert_select "[data-stull-zone]"
      assert_select "[data-reasoning-log] li", minimum: 1
      assert_select "[data-controller='clipboard']"
      assert_select "button[data-clipboard-url-param='/samples/#{sample.id}/export/glazecalc.json']"
      assert_select "a[href='/samples/#{sample.id}/export/glazecalc.json?download=1']"
      assert_select "a[href='/samples/#{sample.id}/export/glaze_vault.json?download=1']"
      assert_includes response.body, "/api/v1/materials/#{sample.id}"
    end
  end

  test "GET /samples/:id renders Stull shift vector when both heuristic and verified lab assays exist" do
    sample = UserSample.create!(
      title: "Calibrated Bluff Clay",
      material_category: :wild_clay,
      latitude: 47.2529,
      longitude: -122.4443
    )
    SamplesController.estimate_sample(sample)
    sample.assay_results.create!(
      source_type: :verified_lab_xrf,
      lab_name: "WSU GeoAnalytical Lab",
      oxides: {
        "SiO2" => 64.5, "Al2O3" => 15.8, "Fe2O3" => 4.2, "CaO" => 4.8,
        "MgO" => 2.1, "Na2O" => 2.4, "K2O" => 2.7, "TiO2" => 0.7,
        "P2O5" => 0.15, "MnO" => 0.05, "LOI" => 2.6
      },
      umf_formula: Chemistry::UmfCalculator.call(
        "SiO2" => 64.5, "Al2O3" => 15.8, "Fe2O3" => 4.2, "CaO" => 4.8,
        "MgO" => 2.1, "Na2O" => 2.4, "K2O" => 2.7, "TiO2" => 0.7,
        "P2O5" => 0.15, "MnO" => 0.05, "LOI" => 2.6
      ),
      confidence_score: 0.98
    )

    get sample_path(sample)
    assert_response :success

    assert_select "svg[data-stull-chart]" do
      assert_select "line[data-stull-shift-vector]"
      assert_select "[data-stull-comparison-point]"
      assert_select "[data-stull-active-point]"
    end
    assert_includes response.body, "WSU GeoAnalytical Lab"
    assert_includes response.body, "Spatial Heuristic → Verified Lab"
  end

  test "GET /samples/:id renders USDA soil profile digging depth card with clay bar and CaCO3 warning" do
    soil = SoilProfile.create!(
      mukey: "468120",
      map_unit_name: "Alderwood gravelly sandy loam, 0 to 8 percent slopes",
      component_name: "Alderwood",
      component_percent: 85,
      max_clay_pct: 42.0,
      max_plasticity_index: 24.0,
      max_caco3_pct: 4.5,
      latitude: 47.2529,
      longitude: -122.4443,
      horizons: [
        { "hzname" => "A", "top_cm" => 0, "bottom_cm" => 35, "clay_pct" => 14.0, "plasticity_index" => 8.0, "caco3_pct" => 0.0 },
        { "hzname" => "Bt", "top_cm" => 35, "bottom_cm" => 90, "clay_pct" => 42.0, "plasticity_index" => 24.0, "caco3_pct" => 4.5 }
      ]
    )
    sample = UserSample.create!(
      title: "Alderwood Subsoil Clay",
      material_category: :wild_clay,
      latitude: 47.2529,
      longitude: -122.4443,
      soil_profile: soil
    )
    SamplesController.estimate_sample(sample)

    get sample_path(sample)
    assert_response :success

    assert_select "#soil_profile_card [data-soil-profile-card]" do
      assert_includes response.body, "Alderwood"
      assert_includes response.body, "85%"
      assert_includes response.body, "MUKEY #468120"
      assert_includes response.body, "Best clay horizon:"
      assert_includes response.body, "35–90 cm"
      assert_includes response.body, "42% clay"
      assert_includes response.body, "PI 24"
      assert_includes response.body, "Expect Vinegar Fizz"
    end
  end

  test "GET /samples/geologic_lookup summarizes cached soil profile inside Turbo Frame" do
    SoilProfile.create!(
      mukey: "468999",
      map_unit_name: "Kitsap silt loam",
      component_name: "Kitsap",
      component_percent: 90,
      max_clay_pct: 38.0,
      max_plasticity_index: 20.0,
      max_caco3_pct: 3.0,
      latitude: 47.2529,
      longitude: -122.4443,
      horizons: [
        { "hzname" => "Bt", "top_cm" => 30, "bottom_cm" => 85, "clay_pct" => 38.0, "plasticity_index" => 20.0, "caco3_pct" => 3.0 }
      ]
    )

    get geologic_lookup_samples_path(lat: 47.2529, lng: -122.4443),
      headers: { "Turbo-Frame" => "geologic_unit_card" }

    assert_response :success
    assert_select "turbo-frame#geologic_unit_card [data-lookup-soil-summary]" do
      assert_includes response.body, "Kitsap"
      assert_includes response.body, "38% clay"
      assert_includes response.body, "Fizz Risk"
    end
  end

  test "POST /samples attaches cached SoilProfile and PATCH clears stale soil_profile on relocation" do
    soil = SoilProfile.create!(
      mukey: "468555",
      map_unit_name: "Tacoma Glacial Till",
      component_name: "Everett",
      component_percent: 80,
      max_clay_pct: 28.0,
      latitude: 47.2529,
      longitude: -122.4443,
      horizons: [
        { "hzname" => "Bt", "top_cm" => 25, "bottom_cm" => 75, "clay_pct" => 28.0, "plasticity_index" => 15.0, "caco3_pct" => 0.0 }
      ]
    )

    post samples_path, params: {
      user_sample: {
        title: "Cached Soil Clay",
        material_category: "wild_clay",
        latitude: "47.2529",
        longitude: "-122.4443"
      }
    }

    sample = UserSample.order(:id).last
    assert_equal soil.id, sample.soil_profile_id

    stub_request(:get, "https://macrostrat.org/api/v2/geologic_units/map")
      .with(query: hash_including("lat" => "10.0", "lng" => "-150.0", "format" => "geojson"))
      .to_return(
        status: 200,
        body: { type: "FeatureCollection", features: [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    patch sample_path(sample), params: {
      user_sample: {
        title: "Cached Soil Clay",
        material_category: "wild_clay",
        latitude: "10.0",
        longitude: "-150.0"
      }
    }

    assert_redirected_to sample_path(sample)
    assert_nil sample.reload.soil_profile_id
  end

  test "PATCH /samples/:id updates sample metadata and recalculates assay" do
    sample = UserSample.create!(
      title: "Original Clay",
      material_category: :wild_clay,
      latitude: 47.2529,
      longitude: -122.4443
    )
    SamplesController.estimate_sample(sample)

    patch sample_path(sample), params: {
      user_sample: {
        title: "Updated Basalt Dust",
        material_category: "crushed_rock"
      }
    }

    assert_redirected_to sample_path(sample)
    sample.reload
    assert_equal "Updated Basalt Dust", sample.title
    assert_equal "crushed_rock", sample.material_category
    assert_not_nil sample.latest_assay_result
  end

  test "PATCH /samples/:id clears stale geologic_unit_id when coordinates move to unmapped location" do
    sample = UserSample.create!(
      title: "Relocated Sample",
      material_category: :wild_clay,
      latitude: 47.2529,
      longitude: -122.4443,
      geologic_unit: @tacoma_unit
    )
    SamplesController.estimate_sample(sample)

    stub_request(:get, "https://macrostrat.org/api/v2/geologic_units/map")
      .with(query: hash_including("lat" => "10.0", "lng" => "-150.0", "format" => "geojson"))
      .to_return(
        status: 200,
        body: { type: "FeatureCollection", features: [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

    patch sample_path(sample), params: {
      user_sample: {
        title: "Relocated Sample",
        material_category: "wild_clay",
        latitude: "10.0",
        longitude: "-150.0",
        geologic_unit_id: @tacoma_unit.id.to_s
      }
    }

    assert_redirected_to sample_path(sample)
    assert_nil sample.reload.geologic_unit_id
  end

  test "DELETE /samples/:id destroys sample and redirects to root" do
    sample = UserSample.create!(title: "Disposable Sample", material_category: :other)

    assert_difference "UserSample.count", -1 do
      delete sample_path(sample)
    end

    assert_redirected_to root_path
  end
end
