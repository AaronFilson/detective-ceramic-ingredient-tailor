# frozen_string_literal: true

class UserSample < ApplicationRecord
  include Geolocatable

  belongs_to :user, optional: true
  belongs_to :geologic_unit, optional: true
  belongs_to :soil_profile, optional: true

  has_many :field_observations, dependent: :destroy
  has_many :assay_results, dependent: :destroy

  enum :material_category, {
    wild_clay: 0,
    crushed_rock: 1,
    wood_ash: 2,
    other: 3
  }

  validates :title, presence: true
  validates :material_category, presence: true

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
end
