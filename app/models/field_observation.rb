# frozen_string_literal: true

class FieldObservation < ApplicationRecord
  ALLOWED_PHOTO_CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze
  MAX_PHOTO_BYTE_SIZE = 10.megabytes

  belongs_to :user_sample

  has_one_attached :raw_tile_photo
  has_one_attached :fired_tile_photo

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
  validate :validate_tile_photos

  def effective_total_shrinkage
    return shrinkage_percent.to_f if shrinkage_percent.present?
    return nil if drying_shrinkage_percent.blank? && firing_shrinkage_percent.blank?

    (drying_shrinkage_percent.to_f + firing_shrinkage_percent.to_f).round(2)
  end

  private

  def validate_tile_photos
    { raw_tile_photo: raw_tile_photo, fired_tile_photo: fired_tile_photo }.each do |attr, attachment|
      next unless attachment.attached?

      blob = attachment.blob
      next unless blob

      unless ALLOWED_PHOTO_CONTENT_TYPES.include?(blob.content_type)
        errors.add(attr, "must be a JPEG, PNG, or WebP image (got #{blob.content_type || 'unknown'})")
      end

      if blob.byte_size.to_i > MAX_PHOTO_BYTE_SIZE
        errors.add(attr, "must be 10 MB or smaller")
      end
    end
  end
end
