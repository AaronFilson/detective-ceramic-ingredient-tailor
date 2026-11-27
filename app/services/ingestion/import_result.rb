# frozen_string_literal: true

module Ingestion
  ImportResult = Struct.new(:imported, :created, :updated, :skipped, :errors, keyword_init: true)
end
