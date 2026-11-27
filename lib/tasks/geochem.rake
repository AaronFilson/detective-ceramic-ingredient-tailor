# frozen_string_literal: true

namespace :geochem do
  desc "Import geochemical reference assays from a USGS NGDB CSV file"
  task :import_usgs, [:path] => :environment do |_task, args|
    path = args[:path]
    raise ArgumentError, "Usage: rake geochem:import_usgs[path/to/file.csv]" if path.blank?
    raise Errno::ENOENT, "File not found: #{path}" unless File.exist?(path)

    result = Ingestion::UsgsCsvImporter.new(path).call
    puts "USGS import complete: imported=#{result.imported} (created=#{result.created}, updated=#{result.updated}), skipped=#{result.skipped}"
  end

  desc "Import geochemical reference assays from an EarthChem CSV/TSV file"
  task :import_earthchem, [:path] => :environment do |_task, args|
    path = args[:path]
    raise ArgumentError, "Usage: rake geochem:import_earthchem[path/to/file.csv]" if path.blank?
    raise Errno::ENOENT, "File not found: #{path}" unless File.exist?(path)

    result = Ingestion::EarthchemCsvImporter.new(path).call
    puts "EarthChem import complete: imported=#{result.imported} (created=#{result.created}, updated=#{result.updated}), skipped=#{result.skipped}"
  end
end
