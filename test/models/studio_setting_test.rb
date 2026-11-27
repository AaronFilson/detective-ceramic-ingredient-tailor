# frozen_string_literal: true

require "test_helper"

class StudioSettingTest < ActiveSupport::TestCase
  setup do
    StudioSetting.delete_all
  end

  test "StudioSetting.current creates singleton with sensible defaults needing onboarding" do
    setting = StudioSetting.current
    assert setting.persisted?
    assert setting.onboarding_needed?
    assert_not setting.onboarding_completed?
    assert_equal "wild_clay", setting.default_material_category
    assert_equal "6", setting.default_fired_cone
    assert_equal "gloss", setting.default_blend_surface
    assert_equal "both", setting.preferred_export_target
    assert_equal "https://glazecalc.com", setting.effective_glazecalc_base_url
    assert_equal setting.id, StudioSetting.current.id
  end

  test "complete_onboarding!, skip_onboarding!, and reset_onboarding! manage lifecycle cleanly" do
    setting = StudioSetting.current
    assert setting.onboarding_needed?

    setting.skip_onboarding!
    assert_not setting.onboarding_needed?
    assert_not setting.onboarding_completed?

    setting.complete_onboarding!(
      studio_name: "Puget Clayworks",
      default_fired_cone: "10",
      default_blend_surface: "matte"
    )
    assert_not setting.onboarding_needed?
    assert setting.onboarding_completed?
    assert_nil setting.onboarding_skipped_at
    assert_equal "10", setting.blend_target_cone
    assert_equal "Puget Clayworks", setting.studio_name

    setting.reset_onboarding!
    assert setting.onboarding_needed?
  end

  test "validates coordinates, zoom, cone, surface, category, and glazecalc_base_url" do
    setting = StudioSetting.new(
      default_lat: 99,
      default_lng: -200,
      default_zoom: 99,
      default_material_category: "invalid",
      default_fired_cone: "99",
      default_blend_surface: "sparkly",
      preferred_export_target: "unknown",
      glazecalc_base_url: "ftp://bad.example"
    )

    assert_not setting.valid?
    assert_includes setting.errors[:default_lat].join, "less than or equal to 90"
    assert_includes setting.errors[:default_lng].join, "greater than or equal to -180"
    assert_includes setting.errors[:default_zoom].join, "less than or equal to 16"
    assert_includes setting.errors[:default_material_category].join, "not included"
    assert_includes setting.errors[:default_fired_cone].join, "not included"
    assert_includes setting.errors[:default_blend_surface].join, "not included"
    assert_includes setting.errors[:preferred_export_target].join, "not included"
    assert_includes setting.errors[:glazecalc_base_url].join, "http(s)"
  end

  test "blend_target_cone maps Cone 06 safely to Cone 6 for glaze blends" do
    setting = StudioSetting.new(default_fired_cone: "06")
    assert_equal "6", setting.blend_target_cone
  end
end
