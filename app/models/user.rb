# frozen_string_literal: true

class User < ApplicationRecord
  has_secure_password validations: false

  enum :role, { member: 0, admin: 1 }

  has_many :sessions, dependent: :destroy
  has_many :api_tokens, dependent: :destroy
  has_many :user_samples, dependent: :destroy
  has_one :studio_setting, dependent: :destroy

  normalizes :email, with: ->(e) { e.to_s.strip.downcase }

  validates :email,
    presence: true,
    uniqueness: { case_sensitive: false },
    format: { with: URI::MailTo::EMAIL_REGEXP }
  validates :password_digest, presence: true, if: -> { password_digest_was.present? }
  validates :password, presence: true, on: %i[registration password_reset]
  validates :password,
    presence: true,
    if: -> { !password.nil? },
    unless: -> { validation_context.in?(%i[registration password_reset]) }
  validates :password,
    length: { minimum: 8, maximum: ActiveModel::SecurePassword::MAX_PASSWORD_LENGTH_ALLOWED },
    confirmation: true,
    if: -> { password.present? }

  generates_token_for :password_reset, expires_in: 30.minutes do
    password_salt&.last(10) if password_digest.present?
  end
end
