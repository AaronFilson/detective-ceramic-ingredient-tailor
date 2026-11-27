# frozen_string_literal: true

module Ingestion
  class UsgsCsvImporter < BaseCsvImporter
    protected

    def default_source
      "usgs_ngdb"
    end

    def external_id_keys
      %w[lab_id field_id sample_id sample_no usgs_id record_no external_id id]
    end

    def rock_type_keys
      %w[rock_type rock_name lithology material sample_type rock_class desc]
    end
  end
end
