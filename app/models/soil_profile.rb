# frozen_string_literal: true

class SoilProfile < ApplicationRecord
  include Geolocatable

  has_many :user_samples, dependent: :nullify

  validates :mukey, presence: true, uniqueness: true

  # Returns the horizon with the highest measured clay percentage (typically B/Bt claypan).
  def clay_rich_horizon
    Array(horizons)
      .select { |h| h.is_a?(Hash) && h["clay_pct"].present? }
      .max_by { |h| h["clay_pct"].to_f }
  end

  def summary_label
    parts = [ component_name.presence || map_unit_name.presence || "Soil Unit ##{mukey}" ]
    if (best = clay_rich_horizon)
      depth = [ best["top_cm"], best["bottom_cm"] ].compact.join("–")
      parts << "#{best["hzname"] || "Horizon"} #{depth} cm: #{best["clay_pct"].to_f.round(0)}% clay"
    end
    parts.join(" · ")
  end
end
