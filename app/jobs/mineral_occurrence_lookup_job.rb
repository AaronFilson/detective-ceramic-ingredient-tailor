# frozen_string_literal: true

class MineralOccurrenceLookupJob < ApplicationJob
  queue_as :default

  DEFAULT_RADIUS_KM = 50

  def perform(lat, lng, radius_km: DEFAULT_RADIUS_KM)
    return [] if lat.blank? || lng.blank?

    results = []
    results.concat(
      Array(
        Clients::UsgsMrdsClient.search_nearby(
          lat: lat,
          lng: lng,
          radius_km: radius_km
        )
      )
    )

    if Clients::MindatClient.configured?
      results.concat(
        Array(
          Clients::MindatClient.search_nearby(
            lat: lat,
            lng: lng,
            radius_km: radius_km
          )
        )
      )
    end

    results.uniq(&:id)
  end
end
