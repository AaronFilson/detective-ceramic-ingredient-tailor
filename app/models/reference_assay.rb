# frozen_string_literal: true

class ReferenceAssay < ApplicationRecord
  include Geolocatable

  validates :source, presence: true
  validates :external_id, uniqueness: { scope: :source }, allow_nil: true

  scope :by_source, ->(source) { where(source: source) }
  scope :by_rock_type, ->(rock_type) { where(rock_type: rock_type) }

  def oxide_value(key)
    val = oxides[key.to_s]
    val.nil? ? nil : val.to_f
  end
end
