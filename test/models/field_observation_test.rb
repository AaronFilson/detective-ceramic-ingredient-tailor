# frozen_string_literal: true

require "test_helper"

class FieldObservationTest < ActiveSupport::TestCase
  setup do
    @sample = UserSample.create!(title: "Riverbank Clay")
  end

  test "requires user_sample" do
    obs = FieldObservation.new
    assert_not obs.valid?
    assert_includes obs.errors[:user_sample], "must exist"
  end

  test "enums match schema contract and vinegar_fizz prefix avoids Relation#none clash" do
    assert_equal({ "none" => 0, "slight" => 1, "vigorous" => 2 }, FieldObservation.defined_enums["vinegar_fizz"])
    assert_equal({ "fast_disintegration" => 0, "slow_flake" => 1, "no_slake" => 2 }, FieldObservation.slaking_behaviors)
    assert_equal({ "short_non_plastic" => 0, "moderate" => 1, "high_plastic" => 2 }, FieldObservation.plasticities)
    assert_equal(
      { "refractory_chalky" => 0, "vitrified_tight" => 1, "bloated" => 2, "melted_fluid" => 3 },
      FieldObservation.melt_states
    )

    obs = @sample.field_observations.create!(
      vinegar_fizz: :vigorous,
      slaking_behavior: :fast_disintegration,
      plasticity: :high_plastic,
      raw_color: "blue-grey",
      fired_cone: "6",
      fired_color: "terracotta brown",
      melt_state: :vitrified_tight,
      shrinkage_percent: 11.25
    )

    assert obs.vinegar_fizz_vigorous?
    assert obs.fast_disintegration?
    assert obs.high_plastic?
    assert obs.vitrified_tight?
    assert_equal BigDecimal("11.25"), obs.shrinkage_percent

    # Relation#none still works cleanly
    assert_equal 0, FieldObservation.none.count
  end

  test "defaults vinegar_fizz to none" do
    obs = @sample.field_observations.create!
    assert obs.vinegar_fizz_none?
  end
end
