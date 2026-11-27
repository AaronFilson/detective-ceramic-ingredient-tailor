# frozen_string_literal: true

require "test_helper"

class EndToEndPlatformTest < ActionDispatch::IntegrationTest
  TACOMA_LAT = 47.2529
  TACOMA_LNG = -122.4443

  MOLECULAR_WEIGHTS = Chemistry::UmfCalculator::MOLECULAR_WEIGHTS

  setup do
    @seed_path = Rails.root.join("db/seeds/sample_assays.csv")
    Ingestion::UsgsCsvImporter.new(@seed_path).call
  end

  test "full studio workflow: seed -> Tacoma WA Macrostrat fetch/cache -> baseline -> vigorous fizz Turbo Stream -> Glazecalc & Glaze-Vault exports & v1 API" do
    # 1. Verify idempotent seeding of all 50 PNW/North American reference assays
    assert_equal 50, ReferenceAssay.count
    second_import = Ingestion::UsgsCsvImporter.new(@seed_path).call
    assert_equal 0, second_import.created
    assert_equal 50, ReferenceAssay.count

    # 2. Drop a pin in Washington State (47.2529, -122.4443) -> Macrostrat fetch + PostGIS cache
    macrostrat_stub = stub_request(:get, "https://macrostrat.org/api/v2/geologic_units/map")
      .with(query: hash_including("lat" => TACOMA_LAT.to_s, "lng" => TACOMA_LNG.to_s, "format" => "geojson"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          type: "FeatureCollection",
          features: [
            {
              type: "Feature",
              geometry: {
                type: "Polygon",
                coordinates: [ [
                  [ -122.65, 47.10 ],
                  [ -122.20, 47.10 ],
                  [ -122.20, 47.40 ],
                  [ -122.65, 47.40 ],
                  [ -122.65, 47.10 ]
                ] ]
              },
              properties: {
                map_id: 472_529,
                name: "Vashon Glacial Drift",
                strat_name: "Fraser Glaciation",
                lith: "Major:{glacial till, clay}, Minor:{silt, gravel}",
                age: "Pleistocene",
                color: "#7BA05B"
              }
            }
          ]
        }.to_json
      )

    ssurgo_stub = stub_request(:post, "https://sdmdataaccess.sc.egov.usda.gov/Tabular/post.rest")
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          Table: [
            [ "472529", "Alderwood-Everett complex", "Alderwood", "85", "Ap", "0", "35", "18", "8", "0" ],
            [ "472529", "Alderwood-Everett complex", "Alderwood", "85", "Bt", "35", "90", "38", "22", "0" ]
          ]
        }.to_json
      )

    get geologic_lookup_samples_path(lat: TACOMA_LAT, lng: TACOMA_LNG),
      headers: { "Turbo-Frame" => "geologic_unit_card" }
    assert_response :success
    assert_requested macrostrat_stub, times: 1
    assert_requested ssurgo_stub, times: 1

    cached_unit = GeologicUnit.find_by!(macrostrat_id: 472_529)
    assert_equal "Vashon Glacial Drift", cached_unit.name
    assert_not_nil cached_unit.boundary

    cached_soil = SoilProfile.find_by!(mukey: "472529")
    assert_equal "Alderwood", cached_soil.component_name

    # Second lookup hits PostGIS ST_Covers cache without issuing a second HTTP call
    post samples_path, params: {
      user_sample: {
        title: "Tacoma Marine Bluff Wild Clay",
        material_category: "wild_clay",
        latitude: TACOMA_LAT.to_s,
        longitude: TACOMA_LNG.to_s,
        notes: "Dug from exposed glacial bank above Commencement Bay"
      }
    }
    assert_requested macrostrat_stub, times: 1

    sample = UserSample.order(:id).last
    assert_redirected_to sample_path(sample)
    assert_equal cached_unit.id, sample.geologic_unit_id
    assert_equal cached_soil.id, sample.soil_profile_id

    # Verify full merged Step 1-3 workbench renders Soil Card, Stull SVG, Lab Calibration, and Glazecalc Push
    get sample_path(sample)
    assert_response :success
    assert_select "svg[data-stull-chart]"
    assert_select "#lab_calibration_panel"
    assert_select "#glazecalc_push_panel"
    assert_includes response.body, "Alderwood"

    baseline_assay = sample.latest_assay_result
    assert_not_nil baseline_assay
    assert baseline_assay.spatial_heuristic_estimate?
    assert_in_delta 100.0, baseline_assay.oxides.values.sum, 0.1
    assert_in_delta 1.0, baseline_assay.umf_formula["flux_total"].to_f, 0.01
    assert baseline_assay.umf_formula["si_al_ratio"].to_f.positive?

    baseline_cao = baseline_assay.oxides.fetch("CaO").to_f
    baseline_loi = baseline_assay.oxides.fetch("LOI").to_f

    # 3. Submit FieldObservation with vinegar_fizz: :vigorous via Turbo Stream (no page reload)
    post sample_field_observations_path(sample),
      params: {
        field_observation: {
          vinegar_fizz: "vigorous",
          slaking_behavior: "fast_disintegration",
          plasticity: "high_plastic",
          raw_color: "terracotta brown",
          fired_cone: "6",
          fired_color: "red brown",
          melt_state: "vitrified_tight",
          shrinkage_percent: "11.2"
        }
      },
      as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, 'target="assay_estimate_panel"'

    updated_assay = sample.reload.latest_assay_result
    assert_operator updated_assay.oxides.fetch("CaO").to_f, :>, baseline_cao,
      "Expected vigorous vinegar fizz to raise CaO above baseline (#{baseline_cao})"
    assert_operator updated_assay.oxides.fetch("LOI").to_f, :>, baseline_loi,
      "Expected vigorous vinegar fizz to raise LOI above baseline (#{baseline_loi})"
    assert_in_delta 100.0, updated_assay.oxides.values.sum, 0.1
    assert updated_assay.reasoning_log.any? { |entry| entry.match?(/vinegar|carbonate|CaO/i) }

    # 4. Export via /samples/:id/export/glazecalc.json -> sum == 100.0% (+/-0.1%) & UMF consistency
    get "/samples/#{sample.id}/export/glazecalc.json"
    assert_response :success

    gc = JSON.parse(response.body)
    assert_equal "Tacoma Marine Bluff Wild Clay", gc["name"]
    assert_equal "percent", gc["percentmole"]
    assert_equal 100.0, gc["molecularweight"].to_f

    oxide_analysis_sum = gc.fetch("oxideAnalysis").values.sum(&:to_f) + gc.fetch("loi").to_f
    assert_in_delta 100.0, oxide_analysis_sum, 0.1

    full_oxides_sum = gc.fetch("oxides").values.sum(&:to_f)
    assert_in_delta 100.0, full_oxides_sum, 0.1

    fields_sum = gc.fetch("fields").sum { |f| f.fetch("amount").to_f } + gc.fetch("loi").to_f
    assert_in_delta 100.0, fields_sum, 0.1

    assert_in_delta 1.0, gc.dig("umf", "flux_total").to_f, 0.01
    assert gc.dig("umf", "si_al_ratio").to_f.positive?

    equivalent = gc.fetch("equivalent").to_f
    assert_operator equivalent, :>, 0.0
    gc.fetch("fields").each do |field|
      mw = MOLECULAR_WEIGHTS.fetch(field.fetch("name"))
      expected_unity = (field.fetch("amount").to_f / 100.0 / mw) * equivalent
      assert_in_delta expected_unity, field.fetch("amountUnity").to_f, [ expected_unity * 0.01, 0.0005 ].max
    end

    # 5a. Export via /samples/:id/export/glaze_vault.json -> Glaze Vault v1 archive + provenance
    get "/samples/#{sample.id}/export/glaze_vault.json"
    assert_response :success

    gv = JSON.parse(response.body)
    assert_equal "glaze-vault-export", gv["format"]
    assert_equal 1, gv["version"]
    assert_equal 1, gv["materials"].size
    assert_equal "Tacoma Marine Bluff Wild Clay", gv.dig("materials", 0, "name")
    assert_equal 472_529, gv.dig("provenance", "geologic_unit", "macrostrat_id")
    assert_equal 1, gv.dig("provenance", "field_observations").size
    assert gv.dig("provenance", "assay_result", "oxide_ranges", "SiO2", "median").present?

    # 5b. API endpoint /api/v1/materials/:id
    get "/api/v1/materials/#{sample.id}"
    assert_response :success

    api_payload = JSON.parse(response.body)
    assert_equal "v1", api_payload["api_version"]
    assert_equal "Tacoma Marine Bluff Wild Clay", api_payload["name"]
    assert_includes api_payload.dig("links", "glazecalc_export"), "/samples/#{sample.id}/export/glazecalc.json"
    assert_includes api_payload.dig("links", "glaze_vault_export"), "/samples/#{sample.id}/export/glaze_vault.json"
  end

  test "hard-rock workflow: DS-801 XRD + PNW mineral atlas -> pXRF CSV + kiln LOI -> hazard screener & full-oxide exports" do
    # 1. Seed curated PNW mineral occurrences & USGS DS-801 C-horizon XRD soils
    minerals_result = Ingestion::MineralOccurrenceSeeder.call
    assert_equal 25, minerals_result.created
    assert_equal 25, MineralOccurrence.count

    ds801_result = Ingestion::UsgsDs801Importer.new(Rails.root.join("db/seeds/sample_ds801_soils.csv")).call
    assert_equal 12, ds801_result.created

    # 2. Verify JSON mineral occurrence API returns PNW deposits sorted by PostGIS distance
    get "/mineral_occurrences.json", params: { lat: TACOMA_LAT, lng: TACOMA_LNG, radius_km: 150 }
    assert_response :success
    occurrences = JSON.parse(response.body)
    assert_operator occurrences.size, :>=, 2
    distances = occurrences.map { |o| o.fetch("distance_km").to_f }
    assert_equal distances.sort, distances

    # 3. Create a crushed hard-rock sample near Puget Sound & verify Step 1 XRD + Mineral Atlas cards render
    sample = UserSample.create!(
      title: "Cascade Pegmatite Feldspar",
      material_category: :crushed_rock,
      latitude: TACOMA_LAT,
      longitude: TACOMA_LNG
    )
    SamplesController.estimate_sample(sample)

    get sample_path(sample)
    assert_response :success
    assert_select "#mineral_occurrences_card"
    assert_select "[data-regional-xrd-card]"
    assert_select "#hazard_alerts_panel"
    assert_includes response.body, "Hard-Rock Minerals"

    # 4. Upload a handheld Bruker pXRF CSV with studio kiln LOI (dry 100g -> fired 94.5g = 5.50% LOI),
    # LCT pegmatite K/Rb pathfinder signal (Rb 850 ppm), minor Cu/Sr/Ba, and As/S hazards
    pxrf_csv = <<~CSV
      File #,DateTime,Application,Method,Si %,Al %,Fe %,Ca %,Mg %,Na %,K %,Ti %,P %,Mn %,Rb ppm,Cs ppm,Sr ppm,Ba ppm,Cu ppm,As ppm,S ppm
      104,2026-11-27 10:00:00,GeoChem,Major+Trace,31.2,9.8,0.6,0.5,0.2,3.1,5.4,0.05,0.08,0.04,850,95,1800,6500,1400,85,12000
    CSV
    uploaded = Rack::Test::UploadedFile.new(StringIO.new(pxrf_csv), "text/csv", original_filename: "bruker_pegmatite.csv")

    post sample_lab_assays_path(sample),
      params: {
        lab_assay: {
          analysis_method: "pxrf",
          csv_file: uploaded,
          dry_weight_g: "100.0",
          fired_weight_g: "94.5",
          lab_name: "Bruker S1 TITAN Studio Scan"
        }
      },
      as: :turbo_stream

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type

    pxrf_assay = sample.reload.latest_verified_lab_assay
    assert_not_nil pxrf_assay
    assert_equal "pxrf", pxrf_assay.analysis_method
    assert_in_delta 5.5, pxrf_assay.oxides["LOI"].to_f, 0.05
    assert_operator pxrf_assay.minor_oxides["BaO"].to_f, :>, 0.5
    assert_operator pxrf_assay.minor_oxides["CuO"].to_f, :>, 0.1
    assert_operator pxrf_assay.minor_oxides["SrO"].to_f, :>, 0.1
    assert_in_delta 850.0, pxrf_assay.trace_elements_ppm["Rb"].to_f, 0.1

    # 5. Render workbench and verify Step 3 Hazard Alerts, K/Rb pill, Food-Safe Caution & Minor Oxides strip
    get sample_path(sample)
    assert_response :success
    assert_select "#hazard_alerts_panel[data-highest-severity='danger']"
    assert_select "[data-food-safe-caution]"
    assert_select "[data-krb-pathfinder]", text: /LCT Li Signal/
    assert_select "[data-hazard-code='toxic_arsenic']"
    assert_select "[data-hazard-code='sulfide_degassing']"
    assert_select "[data-hazard-code='pxrf_light_element_blind_spot']"
    assert_select "[data-hazard-code='lct_pegmatite_pathfinder']"
    assert_select "[data-hazard-code='hard_rock_silica_processing']"
    assert_select "[data-minor-oxides-strip]"
    assert_select "[data-minor-oxide='BaO']"
    assert_select "[data-minor-oxide='CuO']"

    # 6. Verify Glazecalc & Glaze Vault exports include minor oxides, sum to 100.00%, and embed hazard notes
    get "/samples/#{sample.id}/export/glazecalc.json"
    assert_response :success
    gc = JSON.parse(response.body)
    assert_in_delta 100.0, gc.fetch("oxideAnalysis").values.sum(&:to_f) + gc.fetch("loi").to_f, 0.05
    assert_operator gc.dig("oxideAnalysis", "BaO").to_f, :>, 0.0
    assert_operator gc.dig("oxideAnalysis", "CuO").to_f, :>, 0.0
    assert_in_delta 1.0, gc.dig("umf", "flux_total").to_f, 0.01
    assert Array(gc.fetch("notes")).any? { |n| n.match?(/Hazard|Arsenic|Barium|Sulfur/i) }

    get "/samples/#{sample.id}/export/glaze_vault.json"
    assert_response :success
    gv = JSON.parse(response.body)
    assert_equal "pxrf", gv.dig("provenance", "assay_result", "analysis_method")
    assert_operator gv.dig("provenance", "assay_result", "minor_oxides", "BaO").to_f, :>, 0.0
    assert_in_delta 850.0, gv.dig("provenance", "assay_result", "trace_elements_ppm", "Rb").to_f, 0.1
    assert gv.dig("materials", 0, "oxides").any? { |entry| entry["oxide"] == "BaO" }
  end
end
