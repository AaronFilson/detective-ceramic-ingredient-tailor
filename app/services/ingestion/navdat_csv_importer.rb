# frozen_string_literal: true

module Ingestion
  class NavdatCsvImporter < BaseCsvImporter
    HEADER_HINT_PATTERN = /\b(?:sample[\s_-]?id|latitude|lat|sio2|al2o3|rock[\s_-]?name|rock[\s_-]?type)\b/i

    protected

    def default_source
      "navdat"
    end

    def default_sample_media
      "volcanic_rock"
    end

    def external_id_keys
      %w[sample_id navdat_id sample_name igsn external_id lab_id id]
    end

    def rock_type_keys
      %w[rock_name rock_type lithology rock_class material type]
    end

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
