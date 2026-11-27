# frozen_string_literal: true

require "test_helper"

class SetupWizardControllerTest < ActionDispatch::IntegrationTest
  setup do
    StudioSetting.delete_all
  end

  test "first visit to GET / shows the DCI Tailor onboarding modal and branding" do
    get root_path
    assert_response :success
    assert_select "title", /DCI Tailor/
    assert_select "#setup_wizard_modal"
    assert_includes response.body, "Welcome to DCI Tailor"
    assert_includes response.body, "Detective Ceramic Ingredient Tailor"
  end

  test "GET /setup renders full 4-step interactive setup wizard" do
    get setup_path
    assert_response :success
    assert_select "title", /Studio Setup Wizard — DCI Tailor/
    assert_select "[data-controller='setup-wizard']"
    assert_select "[data-setup-wizard-target='stepPanel'][data-step='1']"
    assert_select "[data-setup-wizard-target='stepPanel'][data-step='2']"
    assert_select "[data-setup-wizard-target='stepPanel'][data-step='3']"
    assert_select "[data-setup-wizard-target='stepPanel'][data-step='4']"
  end

  test "PATCH /setup saves studio preferences, dismisses first-time modal, and wires defaults across workbench and blends" do
    patch setup_path, params: {
      studio_setting: {
        studio_name: "Cascade Clayworks",
        home_region_label: "US Southwest",
        default_lat: "35.6870",
        default_lng: "-105.9378",
        default_zoom: "7",
        default_material_category: "crushed_rock",
        default_fired_cone: "10",
        default_blend_surface: "matte",
        show_macrostrat_layer: "0",
        show_reference_assays_layer: "1",
        show_mineral_occurrences_layer: "0",
        has_pxrf_workflow: "1",
        preferred_export_target: "glazecalc",
        glazecalc_base_url: "https://studio.glazecalc.example"
      }
    }

    assert_redirected_to root_path
    setting = StudioSetting.current
    assert setting.onboarding_completed?
    assert_not setting.onboarding_needed?
    assert_equal "Cascade Clayworks", setting.studio_name
    assert_equal "US Southwest", setting.home_region_label
    assert_in_delta 35.687, setting.default_lat.to_f, 0.001
    assert_equal "crushed_rock", setting.default_material_category
    assert_equal "10", setting.default_fired_cone
    assert_equal "matte", setting.default_blend_surface
    assert_not setting.show_macrostrat_layer?
    assert setting.show_reference_assays_layer?
    assert_not setting.show_mineral_occurrences_layer?
    assert setting.has_pxrf_workflow?
    assert_equal "https://studio.glazecalc.example", setting.glazecalc_base_url

    # Subsequent GET / should NOT display the first-time modal and should apply map/layer defaults
    get root_path
    assert_response :success
    assert_select "#setup_wizard_modal", count: 0
    assert_includes response.body, "Cascade Clayworks"
    assert_select "[data-map-picker-macrostrat-visible-value='false']"
    assert_select "input[data-map-picker-target='macrostratToggle']:not([checked])"
    assert_select "input[data-map-picker-target='mineralToggle']:not([checked])"

    # GET /samples/new uses the saved home coordinates and default material category
    get new_sample_path
    assert_response :success
    assert_select "select[name='user_sample[material_category]'] option[selected][value='crushed_rock']"
    assert_select "input[name='user_sample[latitude]'][value='35.687']"

    # GET /blends uses Cone 10 & Matte defaults from StudioSetting when samples exist
    sample = UserSample.create!(
      title: "Test Pegmatite",
      material_category: :crushed_rock,
      latitude: 35.687,
      longitude: -105.9378
    )
    SamplesController.estimate_sample(sample)

    get blends_path
    assert_response :success
    assert_select "input[name='target_cone'][value='10'][checked]"
    assert_select "input[name='surface'][value='matte'][checked]"
    assert_select "a[href='#{setup_path}']"
  end

  test "PATCH /setup with create_starter_sample creates a baseline sample in the configured region" do
    assert_difference [ "UserSample.count", "AssayResult.count" ], 1 do
      patch setup_path, params: {
        create_starter_sample: "1",
        studio_setting: {
          home_region_label: "Pacific Northwest",
          default_lat: "47.2529",
          default_lng: "-122.4443",
          default_zoom: "8",
          default_material_category: "wild_clay",
          default_fired_cone: "6",
          default_blend_surface: "gloss",
          preferred_export_target: "both"
        }
      }
    end

    sample = UserSample.order(:id).last
    assert_redirected_to sample_path(sample)
    assert_equal "Pacific Northwest Starter Wild Clay", sample.title
    assert_not_nil sample.latest_assay_result
  end

  test "POST /setup/skip dismisses modal via Turbo Stream and POST /setup/reset restores prompt" do
    post skip_setup_path, as: :turbo_stream
    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, 'action="remove" target="setup_wizard_modal"'
    assert_not StudioSetting.current.onboarding_needed?

    get root_path
    assert_response :success
    assert_select "#setup_wizard_modal", count: 0

    post reset_setup_path
    assert_redirected_to setup_path
    assert StudioSetting.current.onboarding_needed?
  end

  test "PATCH /setup rejects invalid coordinates with 422" do
    patch setup_path, params: {
      studio_setting: {
        default_lat: "145.0",
        default_lng: "-122.4"
      }
    }

    assert_response :unprocessable_entity
    assert_includes response.body, "must be less than or equal to 90"
  end
end
