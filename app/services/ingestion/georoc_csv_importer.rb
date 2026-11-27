# frozen_string_literal: true

module Ingestion
  class GeorocCsvImporter < BaseCsvImporter
    HEADER_HINT_PATTERN = /\b(?:sample[\s_-]?name|sample[\s_-]?id|sio2|al2o3|latitude)\b/i
    FOOTER_START_PATTERN = /\A\s*"?(?:references\s*:|download(?:ed)?\s+from\s+georoc|abbreviations?\s*:|criteria\s*:)/i

    protected

    def default_source
      "georoc"
    end

    def default_sample_media
      "igneous_rock"
    end

    def external_id_keys
      %w[sample_name sample_id igsn unique_id external_id id]
    end

    def rock_type_keys
      %w[rock_name rock_type rock_texture lithology material]
    end

    def latitude_keys
      %w[latitude_min lat_min latitude lat lat_dd lat_wgs84 dec_lat latitude_dd latitude_max lat_max y]
    end

    def longitude_keys
      %w[longitude_min lon_min lng_min longitude lng lon long lon_dd lng_dd long_dd lon_wgs84 dec_long dec_lon longitude_dd longitude_max lon_max lng_max x]
    end

    def strip_preamble(content)
      lines = content.lines
      header_idx = lines.index do |line|
        (line.include?(",") || line.include?("\t")) && line.match?(HEADER_HINT_PATTERN)
      end
      return content if header_idx.nil? || header_idx.zero?

      lines[header_idx..].join
    end

    # GEOROC downloads append References / Download metadata blocks below the tabular rows.
    def strip_footer(content)
      lines = content.lines
      return content if lines.length <= 1

      footer_idx = lines[1..].index { |line| line.match?(FOOTER_START_PATTERN) }
      return content if footer_idx.nil?

      lines[0..footer_idx].join
    end
  end
end
