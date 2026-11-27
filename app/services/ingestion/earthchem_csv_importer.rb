# frozen_string_literal: true

module Ingestion
  class EarthchemCsvImporter < BaseCsvImporter
    HEADER_HINT_PATTERN = /\b(?:latitude|lat|sio2|al2o3|sample[_\s-]?id|igsn)\b/i

    protected

    def default_source
      "earthchem"
    end

    def external_id_keys
      %w[sample_id igsn specimen_id anal_id external_id lab_id id]
    end

    def rock_type_keys
      %w[rock_name rock_type material lithology type rock_class]
    end

    # EarthChem portal exports occasionally include metadata preamble lines
    # before the tabular header row. Skip leading non-header lines if detected.
    def strip_preamble(content)
      lines = content.lines
      header_idx = lines.index do |line|
        (line.include?(",") || line.include?("\t")) && line.match?(HEADER_HINT_PATTERN)
      end
      return content if header_idx.nil? || header_idx.zero?

      lines[header_idx..].join
    end
  end
end
