# frozen_string_literal: true

class MineralOccurrence < ApplicationRecord
  include Geolocatable

  CERAMIC_COMMODITIES = %w[
    feldspar lithium spodumene petalite lepidolite talc soapstone
    wollastonite kaolin clay bentonite silica quartz quartzite
    dolomite limestone magnesite olivine basalt andesite rhyolite
    granite pegmatite pumice borax colemanite boron barite
    strontium celestite apatite zircon rutile ilmenite iron
    hematite magnetite manganese chromite chromium copper cobalt
    nickel zinc tin vanadium fluorite pyrite
  ].freeze

  validates :source, presence: true
  validates :name, presence: true
  validates :external_id, uniqueness: { scope: :source }, allow_nil: true

  scope :by_source, ->(source) { where(source: source) }

  def all_terms
    (Array(commodities) + Array(minerals)).map { |t| t.to_s.strip.downcase }.reject(&:empty?).uniq
  end

  def ceramic_highlights
    all_terms.select { |term| CERAMIC_COMMODITIES.any? { |c| term.include?(c) } }
  end
end
