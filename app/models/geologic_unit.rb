# frozen_string_literal: true

class GeologicUnit < ApplicationRecord
  IGNORED_LITHOLOGY_KEYS = %w[id lith_id unit_id prop proportion color colour descrip description].freeze

  has_many :user_samples, dependent: :nullify

  validates :macrostrat_id, presence: true, uniqueness: true

  # Extracts an array of unique, downcased lithology terms from the flexible
  # Macrostrat lithology JSONB payload (handles nested arrays, hashes,
  # parenthetical modifiers like "continental glacial (sand, gravel) till",
  # and "Major:{basalt,andesite}, Minor:{tuff}" formatted strings).
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
      parse_lithology_string(obj)
    else
      []
    end
  end

  def parse_lithology_string(raw)
    cleaned = raw.gsub(/\b(?:major|minor|unclassified|incidental)\s*:/i, "")
    parenthetical_terms = []

    without_parens = cleaned.gsub(/\(([^()]*)\)/) do
      inner = Regexp.last_match(1).to_s
      parenthetical_terms.concat(split_clean_tokens(inner))
      " "
    end

    (split_clean_tokens(without_parens) + parenthetical_terms).reject(&:empty?)
  end

  def split_clean_tokens(str)
    str
      .split(/[,;|\{\}\[\]\(\)]+/)
      .map { |term| term.gsub(/\s+/, " ").strip.downcase }
      .reject(&:empty?)
  end
end
