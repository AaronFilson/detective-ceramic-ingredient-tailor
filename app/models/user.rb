# frozen_string_literal: true

class User < ApplicationRecord
  has_many :user_samples, dependent: :nullify

  validates :email, uniqueness: true, allow_blank: true
end
