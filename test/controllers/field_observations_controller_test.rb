# frozen_string_literal: true

require "test_helper"

class FieldObservationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @sample = UserSample.create!(
      title: "Tacoma Glacial Clay Sample",
      material_category: :wild_clay,
      latitude: 47.2529,
      longitude: -122.4443
    )
    @baseline_assay = SamplesController.estimate_sample(@sample)
    @baseline_cao = @baseline_assay.oxides["CaO"].to_f
    @baseline_loi = @baseline_assay.oxides["LOI"].to_f
  end

  test "POST /samples/:sample_id/field_observations with vigorous vinegar_fizz as TURBO_STREAM replaces #assay_estimate_panel with elevated CaO, LOI, and reasoning badges" do
    assert_difference -> { @sample.field_observations.count }, 1 do
      post sample_field_observations_path(@sample),
        params: {
          field_observation: {
            vinegar_fizz: "vigorous",
            slaking_behavior: "fast_disintegration",
            plasticity: "moderate",
            raw_color: "Red terracotta"
          }
        },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type

    # Verify Turbo Stream targets #assay_estimate_panel without full page reload
    assert_includes response.body, '<turbo-stream action="replace" target="assay_estimate_panel">'
    assert_includes response.body, 'id="assay_estimate_panel"'
    assert_includes response.body, '<turbo-stream action="replace" target="field_observation_status">'

    updated_assay = @sample.reload.latest_assay_result
    updated_cao = updated_assay.oxides["CaO"].to_f
    updated_loi = updated_assay.oxides["LOI"].to_f

    assert_operator updated_cao, :>, @baseline_cao,
      "Expected vigorous vinegar fizz to increase CaO (baseline=#{@baseline_cao}, updated=#{updated_cao})"
    assert_operator updated_loi, :>, @baseline_loi,
      "Expected vigorous vinegar fizz to increase LOI (baseline=#{@baseline_loi}, updated=#{updated_loi})"
    assert_in_delta 100.0, updated_assay.oxides.values.sum, 0.1

    # Verify rendered Turbo Stream body shows updated CaO, LOI, and reasoning badge
    assert_includes response.body, format("%.2f%%", updated_cao)
    assert_includes response.body, format("%.2f%%", updated_loi)
    assert_includes response.body, "CaO"
    assert_includes response.body, "LOI"
    assert_match(/vinegar|carbonate|caco3/i, response.body)
  end

  test "POST /samples/:sample_id/field_observations with full fired tile diagnostics updates UMF and reasoning" do
    post sample_field_observations_path(@sample, format: :turbo_stream),
      params: {
        field_observation: {
          vinegar_fizz: "slight",
          slaking_behavior: "slow_flake",
          plasticity: "high_plastic",
          raw_color: "Blue gray",
          fired_cone: "10",
          fired_color: "Cream buff",
          melt_state: "refractory_chalky",
          shrinkage_percent: "11.5"
        }
      }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, '<turbo-stream action="replace" target="assay_estimate_panel">'

    obs = @sample.latest_field_observation
    assert_equal "10", obs.fired_cone
    assert_equal "refractory_chalky", obs.melt_state
    assert_in_delta 11.5, obs.shrinkage_percent.to_f, 0.01

    updated = @sample.latest_assay_result
    assert_operator updated.oxides["Fe2O3"].to_f, :<=, 1.6, "Cream buff fired color should cap Fe2O3"
    assert updated.umf_formula["si_al_ratio"].present?
    assert_includes response.body, "SiO2 : Al2O3 Molar Ratio"
  end

  test "POST /samples/:sample_id/field_observations as HTML redirects to sample workbench" do
    assert_difference -> { @sample.field_observations.count }, 1 do
      post sample_field_observations_path(@sample),
        params: {
          field_observation: {
            vinegar_fizz: "vigorous"
          }
        }
    end

    assert_redirected_to sample_path(@sample)
    assert_operator @sample.reload.latest_assay_result.oxides["CaO"].to_f, :>, @baseline_cao
  end

  test "POST /samples/:sample_id/field_observations with invalid shrinkage returns 422 via Turbo Stream" do
    assert_no_difference -> { @sample.field_observations.count } do
      post sample_field_observations_path(@sample),
        params: {
          field_observation: {
            vinegar_fizz: "none",
            shrinkage_percent: "150"
          }
        },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, '<turbo-stream action="replace" target="field_observation_form">'
    assert_includes response.body, "Shrinkage percent"
  end

  test "PATCH /samples/:sample_id/field_observations/:id updates observation via Turbo Stream" do
    obs = @sample.field_observations.create!(vinegar_fizz: :none, raw_color: "Gray")

    patch sample_field_observation_path(@sample, obs),
      params: {
        field_observation: {
          vinegar_fizz: "vigorous"
        }
      },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_equal "vigorous", obs.reload.vinegar_fizz
    assert_includes response.body, '<turbo-stream action="replace" target="assay_estimate_panel">'
  end

  test "POST /samples/:sample_id/field_observations persists 4 Glaze Vault physical body sheet fields and renders body fit risk badges" do
    post sample_field_observations_path(@sample, format: :turbo_stream),
      params: {
        field_observation: {
          vinegar_fizz: "none",
          plasticity: "high_plastic",
          fired_cone: "6",
          water_of_plasticity: "28.5",
          drying_shrinkage_percent: "8.4",
          firing_shrinkage_percent: "5.2",
          boiling_water_absorption_percent: "7.8"
        }
      }

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type

    obs = @sample.latest_field_observation
    assert_in_delta 28.5, obs.water_of_plasticity.to_f, 0.01
    assert_in_delta 8.4, obs.drying_shrinkage_percent.to_f, 0.01
    assert_in_delta 5.2, obs.firing_shrinkage_percent.to_f, 0.01
    assert_in_delta 7.8, obs.boiling_water_absorption_percent.to_f, 0.01

    assert_includes response.body, "Porous Earthenware / Weeping Risk"
    assert_includes response.body, "High Drying Crack/Warp Risk"
    assert_includes response.body, "data-body-fit-badges"
    assert_includes response.body, "data-stull-chart"
    assert_includes response.body, "WoP 28.5%"
    assert_includes response.body, "Dry 8.4%"
    assert_includes response.body, "Fire 5.2%"
    assert_includes response.body, "Abs 7.8%"
  end

  test "POST /samples/:sample_id/field_observations renders vitreous stoneware badge for functional absorption and safe drying shrinkage" do
    post sample_field_observations_path(@sample, format: :turbo_stream),
      params: {
        field_observation: {
          vinegar_fizz: "none",
          fired_cone: "10",
          water_of_plasticity: "22.0",
          drying_shrinkage_percent: "5.5",
          firing_shrinkage_percent: "6.5",
          boiling_water_absorption_percent: "1.4"
        }
      }

    assert_response :success
    assert_includes response.body, "Vitreous Stoneware (Functional)"
    assert_includes response.body, "Safe Drying Shrinkage"
  end

  test "POST /samples/:sample_id/field_observations with out-of-range boiling absorption returns 422 via Turbo Stream" do
    assert_no_difference -> { @sample.field_observations.count } do
      post sample_field_observations_path(@sample, format: :turbo_stream),
        params: {
          field_observation: {
            vinegar_fizz: "none",
            boiling_water_absorption_percent: "125"
          }
        }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, '<turbo-stream action="replace" target="field_observation_form">'
    assert_includes response.body, "Boiling water absorption percent"
  end

  test "POST /samples/:sample_id/field_observations uploads raw and fired tile photos via Turbo Stream and renders thumbnails" do
    raw_photo = Rack::Test::UploadedFile.new(
      StringIO.new(minimal_jpeg_bytes),
      "image/jpeg",
      true,
      original_filename: "raw_tile.jpg"
    )
    fired_photo = Rack::Test::UploadedFile.new(
      StringIO.new(minimal_jpeg_bytes),
      "image/jpeg",
      true,
      original_filename: "fired_tile.jpg"
    )

    assert_difference -> { @sample.field_observations.count }, 1 do
      post sample_field_observations_path(@sample, format: :turbo_stream),
        params: {
          field_observation: {
            vinegar_fizz: "slight",
            fired_cone: "6",
            fired_color: "Terracotta red",
            melt_state: "vitrified_tight",
            raw_tile_photo: raw_photo,
            fired_tile_photo: fired_photo
          }
        }
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type

    obs = @sample.latest_field_observation
    assert obs.raw_tile_photo.attached?
    assert obs.fired_tile_photo.attached?
    assert_includes response.body, '<turbo-stream action="replace" target="sample_photo_gallery">'
    assert_includes response.body, "data-tile-observation=\"#{obs.id}\""
    assert_includes response.body, "data-history-tile-photos=\"#{obs.id}\""
    assert_includes response.body, "Raw"
    assert_includes response.body, "Fired"

    get sample_path(@sample)
    assert_response :success
    assert_select "#sample_photo_gallery [data-tile-progression-gallery]" do
      assert_select "[data-tile-observation='#{obs.id}'] img", count: 2
      assert_includes response.body, "Cone 6"
      assert_includes response.body, "Terracotta red"
      assert_includes response.body, "Vitrified tight"
    end
  end

  test "POST /samples/:sample_id/field_observations rejects invalid non-image tile photo via Turbo Stream" do
    bad_file = Rack::Test::UploadedFile.new(
      StringIO.new("not an image"),
      "text/plain",
      false,
      original_filename: "tile.txt"
    )

    assert_no_difference -> { @sample.field_observations.count } do
      post sample_field_observations_path(@sample, format: :turbo_stream),
        params: {
          field_observation: {
            vinegar_fizz: "none",
            fired_tile_photo: bad_file
          }
        }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, '<turbo-stream action="replace" target="field_observation_form">'
    assert_includes response.body, "must be a JPEG, PNG, or WebP image"
  end

  private

  def minimal_jpeg_bytes
    "\xFF\xD8\xFF\xE0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xFF\xD9".b
  end
end
