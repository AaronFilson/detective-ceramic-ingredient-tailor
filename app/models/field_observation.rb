# frozen_string_literal: true

class FieldObservation < ApplicationRecord
  belongs_to :user_sample

  enum :vinegar_fizz, {
    none: 0,
    slight: 1,
    vigorous: 2
  }, prefix: true

  enum :slaking_behavior, {
    fast_disintegration: 0,
    slow_flake: 1,
    no_slake: 2
  }

  enum :plasticity, {
    short_non_plastic: 0,
    moderate: 1,
    high_plastic: 2
  }

  enum :melt_state, {
    refractory_chalky: 0,
    vitrified_tight: 1,
    bloated: 2,
    melted_fluid: 3
  }

  validates :shrinkage_percent,
    :water_of_plasticity,
    :drying_shrinkage_percent,
    :firing_shrinkage_percent,
    :boiling_water_absorption_percent,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 100 },
    allow_nil: true

  def effective_total_shrinkage
    return shrinkage_percent.to_f if shrinkage_percent.present?
    return nil if drying_shrinkage_percent.blank? && firing_shrinkage_percent.blank?

    (drying_shrinkage_percent.to_f + firing_shrinkage_percent.to_f).round(2)
  end
end
