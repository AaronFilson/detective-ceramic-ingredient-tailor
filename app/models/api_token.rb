# frozen_string_literal: true

require "digest"

class ApiToken < ApplicationRecord
  TOKEN_PREFIX = "dcit_"

  belongs_to :user

  validates :name, :token_prefix, :token_digest, presence: true
  validates :token_digest, uniqueness: true

  scope :active, -> { where(revoked_at: nil) }

  def self.issue!(user:, name:)
    plaintext = "#{TOKEN_PREFIX}#{SecureRandom.hex(24)}"
    record = create!(
      user: user,
      name: name.to_s.strip,
      token_prefix: plaintext[0, 12],
      token_digest: Digest::SHA256.hexdigest(plaintext)
    )
    [ record, plaintext ]
  end

  def self.authenticate(raw_token)
    cleaned = raw_token.to_s.strip.sub(/\ABearer\s+/i, "").strip
    return nil unless cleaned.start_with?(TOKEN_PREFIX)

    digest = Digest::SHA256.hexdigest(cleaned)
    token = active.includes(:user).find_by(token_digest: digest)
    return nil unless token

    token.update_column(:last_used_at, Time.current)
    token
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  def revoked?
    revoked_at.present?
  end
end
