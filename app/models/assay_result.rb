# frozen_string_literal: true

class AssayResult < ApplicationRecord
  belongs_to :user_sample
  belongs_to :reference_assay, optional: true

  after_destroy :cleanup_orphaned_community_reference_assay

  enum :source_type, {
    spatial_heuristic_estimate: 0,
    verified_lab_xrf: 1,
    verified_lab_icpms: 2
  }

  validates :source_type, presence: true
  validates :confidence_score,
    numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 1 },
    allow_nil: true

  def verified_lab?
    verified_lab_xrf? || verified_lab_icpms?
  end

  private

  def cleanup_orphaned_community_reference_assay
    return unless promoted_to_reference? && reference_assay_id.present?
    return if AssayResult.where(reference_assay_id: reference_assay_id).exists?

    ref_assay = ReferenceAssay.find_by(id: reference_assay_id)
    return unless ref_assay&.source.to_s.start_with?("community_verified_")

    ref_assay.destroy!
  end
end
