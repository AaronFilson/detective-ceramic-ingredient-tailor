# frozen_string_literal: true

class UserSample < ApplicationRecord
  include Geolocatable

  ALLOWED_PHOTO_CONTENT_TYPES = %w[image/jpeg image/png image/webp].freeze
  MAX_PHOTO_BYTE_SIZE = 10.megabytes

  belongs_to :user, optional: true
  belongs_to :geologic_unit, optional: true
  belongs_to :soil_profile, optional: true

  has_many :field_observations, dependent: :destroy
  has_many :assay_results, dependent: :destroy
  has_many_attached :outcrop_photos

  enum :material_category, {
    wild_clay: 0,
    crushed_rock: 1,
    wood_ash: 2,
    other: 3
  }

  validates :title, presence: true
  validates :material_category, presence: true
  validate :validate_outcrop_photos

  scope :for_owner, ->(user:, guest_token:) {
    if user.present?
      where(user_id: user.id)
    elsif Rails.env.production? || ENV["REQUIRE_API_AUTH"] == "1"
      guest_token.present? ? where(user_id: nil, guest_token: guest_token) : none
    elsif guest_token.present?
      where(user_id: nil, guest_token: [ guest_token, nil ])
    else
      where(user_id: nil, guest_token: nil)
    end
  }

  def self.claim_guest!(guest_token:, user:)
    return 0 if guest_token.blank? || user.blank?

    where(user_id: nil, guest_token: guest_token).update_all(
      user_id: user.id,
      guest_token: nil,
      updated_at: Time.current
    )
  end

  def latest_assay_result
    assay_results.order(created_at: :desc, id: :desc).first
  end

  def latest_heuristic_assay_result
    assay_results.spatial_heuristic_estimate.order(created_at: :desc, id: :desc).first
  end

  def latest_verified_lab_assay
    assay_results.where(source_type: [ :verified_lab_xrf, :verified_lab_icpms ]).order(created_at: :desc, id: :desc).first
  end

  def latest_field_observation
    field_observations.order(created_at: :desc, id: :desc).first
  end

  private

  def validate_outcrop_photos
    return unless outcrop_photos.attached?

    outcrop_photos.each do |photo|
      blob = photo.blob
      next unless blob

      unless ALLOWED_PHOTO_CONTENT_TYPES.include?(blob.content_type)
        errors.add(:outcrop_photos, "must be a JPEG, PNG, or WebP image (got #{blob.content_type || 'unknown'})")
      end

      if blob.byte_size.to_i > MAX_PHOTO_BYTE_SIZE
        errors.add(:outcrop_photos, "must each be 10 MB or smaller")
      end
    end
  end
end
