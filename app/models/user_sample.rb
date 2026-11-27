# frozen_string_literal: true

class UserSample < ApplicationRecord
  include Geolocatable

  belongs_to :user, optional: true
  belongs_to :geologic_unit, optional: true

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

  def latest_field_observation
    field_observations.order(created_at: :desc, id: :desc).first
  end
end
