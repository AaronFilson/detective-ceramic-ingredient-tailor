# frozen_string_literal: true

module Geolocatable
  extend ActiveSupport::Concern

  def self.factory
    @factory ||= RGeo::Geographic.spherical_factory(srid: 4326)
  end

  included do
    before_validation :sync_location_from_coordinates!
    validate :validate_coordinate_bounds

    scope :within_radius, ->(lat, lng, radius_meters) {
      where(
        "ST_DWithin(#{table_name}.location, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ?)",
        lng.to_f,
        lat.to_f,
        radius_meters.to_f
      )
    }

    scope :ordered_by_distance, ->(lat, lng) {
      order(
        Arel.sql(
          sanitize_sql_array([
            "ST_Distance(#{table_name}.location, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography) ASC",
            lng.to_f,
            lat.to_f
          ])
        )
      )
    }

    scope :with_distance_from, ->(lat, lng) {
      select(
        Arel.sql(
          sanitize_sql_array([
            "#{table_name}.*, ST_Distance(#{table_name}.location, ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography) AS distance_meters",
            lng.to_f,
            lat.to_f
          ])
        )
      )
    }
  end

  def latitude
    @pending_latitude_set ? @pending_latitude : location&.y
  end

  def longitude
    @pending_longitude_set ? @pending_longitude : location&.x
  end

  def latitude=(value)
    @pending_latitude_set = true
    @invalid_latitude = false
    @pending_latitude = parse_coordinate(value) { @invalid_latitude = true }
    sync_location_from_coordinates!
  end

  def longitude=(value)
    @pending_longitude_set = true
    @invalid_longitude = false
    @pending_longitude = parse_coordinate(value) { @invalid_longitude = true }
    sync_location_from_coordinates!
  end

  def location=(value)
    @pending_latitude_set = false
    @pending_longitude_set = false
    @pending_latitude = nil
    @pending_longitude = nil
    @invalid_latitude = false
    @invalid_longitude = false
    super
  end

  private

  def parse_coordinate(value)
    return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)

    num = Float(value)
    if num.nan? || num.infinite?
      yield
      return nil
    end
    num
  rescue ArgumentError, TypeError
    yield
    nil
  end

  def sync_location_from_coordinates!
    return unless @pending_latitude_set || @pending_longitude_set

    lat = @pending_latitude_set ? @pending_latitude : location&.y
    lng = @pending_longitude_set ? @pending_longitude : location&.x

    if lat.is_a?(Numeric) && lng.is_a?(Numeric) &&
        lat.between?(-90.0, 90.0) && lng.between?(-180.0, 180.0)
      write_attribute(:location, Geolocatable.factory.point(lng, lat))
    elsif lat.nil? && lng.nil?
      write_attribute(:location, nil)
    end
  end

  def validate_coordinate_bounds
    if @invalid_latitude
      errors.add(:latitude, "must be a valid number")
    elsif latitude.is_a?(Numeric) && !latitude.between?(-90.0, 90.0)
      errors.add(:latitude, "must be between -90 and 90")
    end

    if @invalid_longitude
      errors.add(:longitude, "must be a valid number")
    elsif longitude.is_a?(Numeric) && !longitude.between?(-180.0, 180.0)
      errors.add(:longitude, "must be between -180 and 180")
    end
  end
end
