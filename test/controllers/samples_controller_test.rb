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
    stub_request(:post, "https://sdmdataaccess.sc.egov.usda.gov/Tabular/post.rest")
      .to_return(
        status: 200,
        body: {
          Table: [
            [ "472529", "Alderwood gravelly sandy loam", "Alderwood", "85", "Bt", "35", "90", "38", "22", "0" ]
          ]
        }.to_json,
        headers: { "Content-Type" => "application/json" }
      )

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
      assert_includes response.body, "Alderwood"
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

  test "GET / renders Hard-Rock Minerals layer toggle and embeds MineralOccurrence JSON payload" do
    MineralOccurrence.create!(
      source: "usgs_mrds",
      external_id: "MRDS-TAC-1",
      name: "Enumclaw Andesite & Feldspar Quarry",
      deposit_type: "Volcanic quarry",
      commodities: [ "Feldspar", "Andesite" ],
      minerals: [ "Plagioclase", "Quartz" ],
      latitude: 47.2043,
      longitude: -121.9915
    )

    get root_path
    assert_response :success

    assert_select "input[type='checkbox'][data-map-picker-target='mineralToggle'][data-action='change->map-picker#toggleMineralOccurrences']"
    assert_includes response.body, "Hard-Rock Minerals (1)"

    root_el = css_select("[data-controller='map-picker']").first
    payload = JSON.parse(root_el["data-map-picker-mineral-occurrences-value"])
    assert_equal 1, payload.size
    assert_equal "Enumclaw Andesite & Feldspar Quarry", payload.first["name"]
    assert_equal "usgs_mrds", payload.first["source"]
    assert_equal "Volcanic quarry", payload.first["deposit_type"]
    assert_includes payload.first["commodities"], "Feldspar"
    assert_includes payload.first["ceramic_highlights"], "feldspar"
  end

  test "GET /samples/:id renders Minor / Hard-Rock Glaze Oxides strip when minor_oxides present" do
    sample = UserSample.create!(
      title: "Spokane Lithium Pegmatite",
      material_category: :crushed_rock,
      latitude: 47.5580,
      longitude: -117.0780
    )
    sample.assay_results.create!(
      source_type: :verified_lab_xrf,
      lab_name: "Hard-Rock Lab",
      oxides: {
        "SiO2" => 71.0, "Al2O3" => 16.5, "Fe2O3" => 0.4, "CaO" => 0.5,
        "MgO" => 0.2, "Na2O" => 3.6, "K2O" => 6.4, "TiO2" => 0.05,
        "P2O5" => 0.15, "MnO" => 0.1, "LOI" => 1.1
      },
      minor_oxides: {
        "Li2O" => 1.42,
        "B2O3" => 0.35,
        "BaO" => 0.18,
        "F" => 0.28
      },
      umf_formula: Chemistry::UmfCalculator.call(
        "SiO2" => 71.0, "Al2O3" => 16.5, "Fe2O3" => 0.4, "CaO" => 0.5,
        "MgO" => 0.2, "Na2O" => 3.6, "K2O" => 6.4, "TiO2" => 0.05,
        "P2O5" => 0.15, "MnO" => 0.1, "LOI" => 1.1
      ),
      confidence_score: 0.96
    )

    get sample_path(sample)
    assert_response :success

    assert_select "[data-minor-oxides-strip]" do
      assert_includes response.body, "Minor / Hard-Rock Glaze Oxides"
      assert_select "[data-minor-oxide='Li2O']", text: /1\.42%/
      assert_select "[data-minor-oxide='B2O3']", text: /0\.35%/
      assert_select "[data-minor-oxide='BaO']", text: /0\.18%/
      assert_select "[data-minor-oxide='F']", text: /Volatile/
    end
  end

  test "lookup_soil_profile falls back to ISRIC SoilGrids when USDA SSURGO returns nil" do
    stub_request(:post, "https://sdmdataaccess.sc.egov.usda.gov/Tabular/post.rest")
      .to_return(status: 200, body: { Table: [] }.to_json, headers: { "Content-Type" => "application/json" })

    # Placed ~330m north of (51.500, -0.120): outside SSURGO's 250m cache, inside SoilGrids' 500m cache
    fallback_profile = SoilProfile.create!(
      mukey: "soilgrids:51.503:-0.120",
      source: "isric_soilgrids",
      map_unit_name: "ISRIC SoilGrids v2 (250m Global)",
      component_name: "Clay Loam",
      max_clay_pct: 32.0,
      latitude: 51.503,
      longitude: -0.120
    )

    if defined?(Clients::IsricSoilgridsClient)
      result = SamplesController.lookup_soil_profile(lat: 51.500, lng: -0.120)
      assert_equal fallback_profile.id, result.id
    else
      fake_isric = Module.new do
        define_singleton_method(:lookup) do |lat:, lng:|
          @last_call = [ lat, lng ]
          fallback_profile
        end

        define_singleton_method(:last_call) { @last_call }
      end

      Clients.const_set(:IsricSoilgridsClient, fake_isric)
      begin
        result = SamplesController.lookup_soil_profile(lat: 51.500, lng: -0.120)
        assert_equal fallback_profile.id, result.id
        assert_equal [ 51.5, -0.12 ], fake_isric.last_call
      ensure
        Clients.send(:remove_const, :IsricSoilgridsClient)
      end
    end
  end

  test "POST /samples enqueues MineralOccurrenceLookupJob only when no usgs_mrds occurrence exists within 50 km" do
    if defined?(MineralOccurrenceLookupJob)
      assert_enqueued_with(job: MineralOccurrenceLookupJob) do
        post samples_path, params: {
          user_sample: {
            title: "First Tacoma Sample",
            material_category: "wild_clay",
            latitude: "47.2529",
            longitude: "-122.4443"
          }
        }
      end

      MineralOccurrence.create!(
        source: "usgs_mrds",
        external_id: "MRDS-NEAR-1",
        name: "Nearby MRDS Deposit",
        latitude: 47.26,
        longitude: -122.44
      )

      assert_no_enqueued_jobs(only: MineralOccurrenceLookupJob) do
        post samples_path, params: {
          user_sample: {
            title: "Second Tacoma Sample",
            material_category: "wild_clay",
            latitude: "47.2529",
            longitude: "-122.4443"
          }
        }
      end
    else
      enqueued_calls = []
      fake_job = Module.new do
        define_singleton_method(:perform_later) do |lat, lng|
          enqueued_calls << [ lat, lng ]
        end
      end

      Object.const_set(:MineralOccurrenceLookupJob, fake_job)
      begin
        post samples_path, params: {
          user_sample: {
            title: "First Tacoma Sample",
            material_category: "wild_clay",
            latitude: "47.2529",
            longitude: "-122.4443"
          }
        }
        assert_equal 1, enqueued_calls.size
        assert_in_delta 47.2529, enqueued_calls.first[0], 0.0001
        assert_in_delta(-122.4443, enqueued_calls.first[1], 0.0001)

        MineralOccurrence.create!(
          source: "usgs_mrds",
          external_id: "MRDS-NEAR-1",
          name: "Nearby MRDS Deposit",
          latitude: 47.26,
          longitude: -122.44
        )

        post samples_path, params: {
          user_sample: {
            title: "Second Tacoma Sample",
            material_category: "wild_clay",
            latitude: "47.2529",
            longitude: "-122.4443"
          }
        }
        assert_equal 1, enqueued_calls.size
      ensure
        Object.send(:remove_const, :MineralOccurrenceLookupJob)
      end
    end
  end

  test "POST /samples uploads outcrop photo, auto-pins coordinates from EXIF GPS, links GeologicUnit, and renders photo gallery" do
    photo = build_uploaded_exif_jpeg(lat: 47.2529, lng: -122.4443, filename: "tacoma_outcrop.jpg")

    assert_difference [ "UserSample.count", "AssayResult.count" ], 1 do
      post samples_path, params: {
        auto_pin_from_photo: "1",
        user_sample: {
          title: "EXIF Auto-Pinned Bluff Clay",
          material_category: "wild_clay",
          latitude: "35.6870",
          longitude: "-105.9378",
          outcrop_photos: [ photo ]
        }
      }
    end

    sample = UserSample.order(:id).last
    assert_redirected_to sample_path(sample)
    assert_includes flash[:notice], "Pinned coordinates (47.2529, -122.4443) automatically from outcrop photo EXIF GPS."
    assert_in_delta 47.2529, sample.latitude, 0.0001
    assert_in_delta(-122.4443, sample.longitude, 0.0001)
    assert_equal @tacoma_unit.id, sample.geologic_unit_id
    assert_equal 1, sample.outcrop_photos.count
    assert_equal "tacoma_outcrop.jpg", sample.outcrop_photos.first.filename.to_s

    get sample_path(sample)
    assert_response :success
    assert_select "#sample_photo_gallery [data-outcrop-photo-grid] img", count: 1
    assert_includes response.body, "tacoma_outcrop.jpg"
  end

  test "POST /samples auto-pins from EXIF GPS when coordinates are blank even without auto_pin_from_photo checkbox" do
    photo = build_uploaded_exif_jpeg(lat: 47.2529, lng: -122.4443, filename: "blank_coords_exif.jpg")

    post samples_path, params: {
      user_sample: {
        title: "Blank Coords EXIF Clay",
        material_category: "wild_clay",
        latitude: "",
        longitude: "",
        outcrop_photos: [ photo ]
      }
    }

    sample = UserSample.order(:id).last
    assert_redirected_to sample_path(sample)
    assert_in_delta 47.2529, sample.latitude, 0.0001
    assert_in_delta(-122.4443, sample.longitude, 0.0001)
    assert_equal @tacoma_unit.id, sample.geologic_unit_id
  end

  test "PATCH /samples/:id attaches additional outcrop photos without deleting existing photos" do
    sample = UserSample.create!(
      title: "Multi-Photo Outcrop Clay",
      material_category: :wild_clay,
      latitude: 47.2529,
      longitude: -122.4443
    )
    sample.outcrop_photos.attach(
      io: StringIO.new(minimal_jpeg_bytes),
      filename: "seam_first.jpg",
      content_type: "image/jpeg"
    )
    SamplesController.estimate_sample(sample)
    assert_equal 1, sample.outcrop_photos.count

    second_photo = Rack::Test::UploadedFile.new(
      StringIO.new(minimal_jpeg_bytes),
      "image/jpeg",
      true,
      original_filename: "seam_second.jpg"
    )

    patch sample_path(sample), params: {
      user_sample: {
        title: "Multi-Photo Outcrop Clay",
        material_category: "wild_clay",
        outcrop_photos: [ second_photo ]
      }
    }

    assert_redirected_to sample_path(sample)
    filenames = sample.reload.outcrop_photos.map { |p| p.filename.to_s }.sort
    assert_equal [ "seam_first.jpg", "seam_second.jpg" ], filenames
  end

  test "POST /samples rejects non-image outcrop upload with 422" do
    bad_file = Rack::Test::UploadedFile.new(
      StringIO.new("not an image payload"),
      "text/plain",
      false,
      original_filename: "notes.txt"
    )

    assert_no_difference "UserSample.count" do
      post samples_path, params: {
        user_sample: {
          title: "Invalid Photo Sample",
          material_category: "wild_clay",
          latitude: "47.2529",
          longitude: "-122.4443",
          outcrop_photos: [ bad_file ]
        }
      }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "must be a JPEG, PNG, or WebP image"
  end

  test "PATCH /samples/:id rejects non-image outcrop upload with 422 while preserving existing photo" do
    sample = UserSample.create!(
      title: "Protected Photo Sample",
      material_category: :wild_clay,
      latitude: 47.2529,
      longitude: -122.4443
    )
    sample.outcrop_photos.attach(
      io: StringIO.new(minimal_jpeg_bytes),
      filename: "valid_outcrop.jpg",
      content_type: "image/jpeg"
    )
    SamplesController.estimate_sample(sample)

    bad_file = Rack::Test::UploadedFile.new(
      StringIO.new("plain text"),
      "text/plain",
      false,
      original_filename: "bad.txt"
    )

    patch sample_path(sample), params: {
      user_sample: {
        title: "Protected Photo Sample",
        outcrop_photos: [ bad_file ]
      }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "must be a JPEG, PNG, or WebP image"
    assert_equal [ "valid_outcrop.jpg" ], sample.reload.outcrop_photos.map { |p| p.filename.to_s }
  end

  private

  def minimal_jpeg_bytes
    "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xFF\xD9".b
  end

  def build_uploaded_exif_jpeg(lat:, lng:, filename:)
    lat_ref = lat >= 0 ? "N\x00\x00\x00".b : "S\x00\x00\x00".b
    lng_ref = lng >= 0 ? "E\x00\x00\x00".b : "W\x00\x00\x00".b
    lat_dms = decimal_to_dms(lat.abs)
    lng_dms = decimal_to_dms(lng.abs)

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
    jpeg = "\xFF\xD8\xFF\xE1".b + [ app1_payload.bytesize + 2 ].pack("n") + app1_payload + "\xFF\xD9".b

    Rack::Test::UploadedFile.new(StringIO.new(jpeg), "image/jpeg", true, original_filename: filename)
  end

  def decimal_to_dms(decimal)
    deg = decimal.floor
    rem_min = (decimal - deg) * 60.0
    min = rem_min.floor
    sec = ((rem_min - min) * 60.0 * 10_000).round
    [ [ deg, 1 ], [ min, 1 ], [ sec, 10_000 ] ]
  end
end
