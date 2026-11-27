# frozen_string_literal: true

require "csv"

module Ingestion
  class MineralOccurrenceSeeder
    DEFAULT_PATH = Rails.root.join("db/seeds/pnw_mineral_occurrences.csv")
    DEFAULT_SOURCE = "pnw_curated_atlas"

    def self.call(path = DEFAULT_PATH)
      new(path).call
    end

    def initialize(path = DEFAULT_PATH)
      @path = path
    end

    def call
      created = 0
      updated = 0
      skipped = 0
      errors = []

      rows = CSV.parse(read_content, headers: true, liberal_parsing: true)
      rows.each_with_index do |row, index|
        line_number = index + 2
        attrs = extract_attributes(row)

        if attrs.nil?
          skipped += 1
          errors << "Row #{line_number}: missing required source/name or valid coordinates"
          next
        end

        outcome = upsert_occurrence(attrs)
        if outcome == :created
          created += 1
        else
          updated += 1
        end
      rescue ActiveRecord::RecordInvalid => e
        skipped += 1
        errors << "Row #{line_number}: #{e.message}"
      end

      ImportResult.new(
        imported: created + updated,
        created: created,
        updated: updated,
        skipped: skipped,
        errors: errors
      )
    end

    private

    def read_content
      if @path.respond_to?(:read)
        @path.read.to_s
      else
        File.read(@path.to_s, encoding: "bom|utf-8")
      end
    end

    def extract_attributes(row)
      normalized = row.to_h.each_with_object({}) do |(key, value), acc|
        next if key.nil?

        acc[key.to_s.strip.downcase] = value
      end

      source = present_string(normalized["source"]) || DEFAULT_SOURCE
      external_id = present_string(normalized["external_id"])
      name = present_string(normalized["name"])
      lat = parse_float(normalized["latitude"] || normalized["lat"])
      lng = parse_float(normalized["longitude"] || normalized["lng"] || normalized["lon"])

      return nil if name.nil? || external_id.nil?
      return nil if lat.nil? || lng.nil? || !lat.between?(-90.0, 90.0) || !lng.between?(-180.0, 180.0)

      {
        source: source,
        external_id: external_id,
        name: name,
        latitude: lat,
        longitude: lng,
        deposit_type: present_string(normalized["deposit_type"]),
        commodities: split_list(normalized["commodities"]),
        minerals: split_list(normalized["minerals"]),
        raw_metadata: {
          "ceramic_role" => present_string(normalized["ceramic_role"]),
          "state" => present_string(normalized["state"]),
          "region" => present_string(normalized["region"]),
          "notes" => present_string(normalized["notes"])
        }.compact
      }
    end

    def upsert_occurrence(attrs)
      record = MineralOccurrence.find_or_initialize_by(
        source: attrs[:source],
        external_id: attrs[:external_id]
      )
      was_new = record.new_record?
      apply_attributes(record, attrs)
      record.save!
      was_new ? :created : :updated
    rescue ActiveRecord::RecordNotUnique
      record = MineralOccurrence.find_by!(
        source: attrs[:source],
        external_id: attrs[:external_id]
      )
      apply_attributes(record, attrs)
      record.save!
      :updated
    end

    def apply_attributes(record, attrs)
      record.name = attrs[:name]
      record.deposit_type = attrs[:deposit_type]
      record.commodities = attrs[:commodities]
      record.minerals = attrs[:minerals]
      record.location = Geolocatable.factory.point(attrs[:longitude], attrs[:latitude])
      record.raw_metadata = attrs[:raw_metadata]
    end

    def split_list(raw)
      return [] if raw.nil?

      raw.to_s.split(/[;,|]+/).map(&:strip).reject(&:empty?).uniq
    end

    def present_string(value)
      return nil if value.nil?

      str = value.to_s.strip
      str.empty? ? nil : str
    end

    def parse_float(value)
      return nil if value.nil? || (value.is_a?(String) && value.strip.empty?)

      num = Float(value)
      return nil if num.nan? || num.infinite?

      num
    rescue ArgumentError, TypeError
      nil
    end
  end
end
