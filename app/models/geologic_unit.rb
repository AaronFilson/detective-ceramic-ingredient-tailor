# frozen_string_literal: true

class GeologicUnit < ApplicationRecord
  IGNORED_LITHOLOGY_KEYS = %w[id lith_id unit_id prop proportion color colour].freeze

  has_many :user_samples, dependent: :nullify

  validates :macrostrat_id, presence: true, uniqueness: true

  # Extracts an array of unique, downcased lithology terms from the flexible
  # Macrostrat lithology JSONB payload (handles nested arrays, hashes, or
  # "Major:{basalt,andesite}, Minor:{tuff}" formatted strings).
  def lithology_terms
    extract_terms(lithology).uniq
  end

  private

  def extract_terms(obj)
    case obj
    when Hash
      obj.flat_map do |key, val|
        key_str = key.to_s.downcase
        next [] if IGNORED_LITHOLOGY_KEYS.include?(key_str) || key_str.end_with?("_id")

        extract_terms(val)
      end
    when Array
      obj.flat_map { |item| extract_terms(item) }
    when String
      cleaned = obj.gsub(/\b(?:major|minor|unclassified|incidental)\s*:/i, "")
      cleaned
        .split(/[,;|\{\}\[\]]+/)
        .map { |term| term.strip.downcase }
        .reject(&:empty?)
    else
      []
    end
  end
end
