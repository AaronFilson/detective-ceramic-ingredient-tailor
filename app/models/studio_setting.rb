# frozen_string_literal: true

class StudioSetting < ApplicationRecord
  belongs_to :user, optional: true

  MATERIAL_CATEGORIES = %w[wild_clay crushed_rock wood_ash other].freeze
  CONE_OPTIONS = %w[06 6 10].freeze
  SURFACE_OPTIONS = %w[gloss matte].freeze
  EXPORT_TARGETS = %w[glazecalc glaze_vault both].freeze

  REGION_PRESETS = [
    {
      key: "pnw",
      label: "Pacific Northwest",
      subtitle: "Puget Sound, Cascades & Columbia Basin",
      lat: 47.2529,
      lng: -122.4443,
      zoom: 8
    },
    {
      key: "us_southwest",
      label: "US Southwest",
      subtitle: "New Mexico, Arizona & Colorado Plateau",
      lat: 35.6870,
      lng: -105.9378,
      zoom: 7
    },
    {
      key: "us_southeast",
      label: "US Southeast & Appalachia",
      subtitle: "Blue Ridge Pegmatites & Georgia Kaolin",
      lat: 35.5951,
      lng: -82.5515,
      zoom: 7
    },
    {
      key: "us_midwest",
      label: "US Midwest & Great Lakes",
      subtitle: "Glacial Till, Driftless & Underclays",
      lat: 42.0308,
      lng: -93.6319,
      zoom: 7
    },
    {
      key: "us_northeast",
      label: "US Northeast",
      subtitle: "New England Granites & Marine Clays",
      lat: 42.3601,
      lng: -71.0589,
      zoom: 7
    },
    {
      key: "europe_uk",
      label: "UK & Western Europe",
      subtitle: "SoilGrids v2 Global 250m Coverage",
      lat: 51.8000,
      lng: -1.2000,
      zoom: 6
    },
    {
      key: "east_asia",
      label: "Japan & East Asia",
      subtitle: "Volcanic Arcs & Ceramic Stoneware Belts",
      lat: 35.0116,
      lng: 135.7681,
      zoom: 7
    }
  ].freeze

  validates :default_lat,
    numericality: { greater_than_or_equal_to: -90, less_than_or_equal_to: 90 }
  validates :default_lng,
    numericality: { greater_than_or_equal_to: -180, less_than_or_equal_to: 180 }
  validates :default_zoom,
    numericality: { only_integer: true, greater_than_or_equal_to: 2, less_than_or_equal_to: 16 }
  validates :default_material_category, inclusion: { in: MATERIAL_CATEGORIES }
  validates :default_fired_cone, inclusion: { in: CONE_OPTIONS }
  validates :default_blend_surface, inclusion: { in: SURFACE_OPTIONS }
  validates :preferred_export_target, inclusion: { in: EXPORT_TARGETS }
  validates :glazecalc_base_url, format: {
    with: /\Ahttps?:\/\/[^\s]+\z/i,
    message: "must be a valid http(s) URL"
  }, allow_blank: true

  before_validation :normalize_defaults

  def self.current
    if Current.user.present? || Current.guest_token.present?
      for_context(user: Current.user, guest_token: Current.guest_token)
    else
      where(user_id: nil, guest_token: nil).order(:id).first || order(:id).first || create!
    end
  end

  def self.for_context(user:, guest_token:)
    if user.present?
      find_or_create_by!(user_id: user.id)
    elsif guest_token.present?
      existing = find_by(guest_token: guest_token)
      return existing if existing

      unclaimed = where(user_id: nil, guest_token: nil).order(:id).first
      if unclaimed
        unclaimed.update_column(:guest_token, guest_token)
        unclaimed
      else
        create!(guest_token: guest_token)
      end
    else
      where(user_id: nil, guest_token: nil).order(:id).first || create!
    end
  end

  def self.claim_guest!(guest_token:, user:)
    return nil if guest_token.blank? || user.blank?

    guest_setting = find_by(user_id: nil, guest_token: guest_token)
    return user.studio_setting if guest_setting.nil?

    if exists?(user_id: user.id)
      guest_setting.destroy
      find_by(user_id: user.id)
    else
      guest_setting.update!(user: user, guest_token: nil)
      guest_setting
    end
  end

  def onboarding_needed?
    onboarding_completed_at.nil? && onboarding_skipped_at.nil?
  end

  def onboarding_completed?
    onboarding_completed_at.present?
  end

  def complete_onboarding!(attributes = {})
    assign_attributes(attributes)
    self.onboarding_completed_at = Time.current
    self.onboarding_skipped_at = nil
    save!
  end

  def skip_onboarding!
    update!(onboarding_skipped_at: Time.current)
  end

  def reset_onboarding!
    update!(onboarding_completed_at: nil, onboarding_skipped_at: nil)
  end

  def blend_target_cone
    default_fired_cone == "10" ? "10" : "6"
  end

  def effective_glazecalc_base_url
    glazecalc_base_url.presence || Clients::GlazecalcPushClient::DEFAULT_BASE_URL
  end

  private

  def normalize_defaults
    self.studio_name = studio_name.to_s.strip
    self.home_region_label = home_region_label.to_s.strip.presence || "Custom Region"
    self.glazecalc_base_url = glazecalc_base_url.to_s.strip.presence || Clients::GlazecalcPushClient::DEFAULT_BASE_URL
  end
end
