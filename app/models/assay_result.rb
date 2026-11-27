# frozen_string_literal: true

class AssayResult < ApplicationRecord
  belongs_to :user_sample

  enum :source_type, {
    spatial_heuristic_estimate: 0,
    verified_lab_xrf: 1,
    verified_lab_icpms: 2
  }

  validates :source_type, presence: true
  validates :confidence_score,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
    allow_nil: true
end
