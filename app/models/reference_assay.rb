# frozen_string_literal: true

require "digest"

class ReferenceAssay < ApplicationRecord
  include Geolocatable

  COORDINATE_PRIVACY_MODES = %w[exact fuzzed_2km].freeze
  KM_PER_DEGREE_LAT = 111.1949266

  belongs_to :promoted_by_user, class_name: "User", optional: true

  validates :source, presence: true
  validates :external_id, uniqueness: { scope: :source }, allow_nil: true
  validates :coordinate_privacy, inclusion: { in: COORDINATE_PRIVACY_MODES }

  scope :by_source, ->(source) { where(source: source) }
  scope :by_rock_type, ->(rock_type) { where(rock_type: rock_type) }

  def self.fuzz_coordinates(lat, lng, seed_key: nil)
    lat_f = Float(lat)
    lng_f = Float(lng)

    if seed_key.present?
      digest = Digest::SHA256.hexdigest(seed_key.to_s)
      u_dist = digest[0, 8].to_i(16) / 4_294_967_295.0
      u_bearing = digest[8, 8].to_i(16) / 4_294_967_295.0
    else
      u_dist = SecureRandom.random_number
      u_bearing = SecureRandom.random_number
    end

    distance_km = 1.6 + (u_dist * 0.8)
    bearing_rad = u_bearing * 2.0 * Math::PI

    delta_north_km = distance_km * Math.cos(bearing_rad)
    delta_east_km = distance_km * Math.sin(bearing_rad)
    cos_lat = [ Math.cos(lat_f * Math::PI / 180.0).abs, 0.01 ].max
    km_per_deg_lng = KM_PER_DEGREE_LAT * cos_lat

    fuzzed_lat = (lat_f + (delta_north_km / KM_PER_DEGREE_LAT)).clamp(-90.0, 90.0).round(4)
    fuzzed_lng = (lng_f + (delta_east_km / km_per_deg_lng)).clamp(-180.0, 180.0).round(4)

    [ fuzzed_lat, fuzzed_lng ]
  end

  def oxide_value(key)
    val = oxides[key.to_s]
    val.nil? ? nil : val.to_f
  end
end
