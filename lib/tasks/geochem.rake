# frozen_string_literal: true

namespace :geochem do
  desc "Import geochemical reference assays from a USGS NGDB CSV file"
  task :import_usgs, [ :path ] => :environment do |_task, args|
    path = args[:path]
    raise ArgumentError, "Usage: rake geochem:import_usgs[path/to/file.csv]" if path.blank?
    raise Errno::ENOENT, "File not found: #{path}" unless File.exist?(path)

    result = Ingestion::UsgsCsvImporter.new(path).call
    puts "USGS import complete: imported=#{result.imported} (created=#{result.created}, updated=#{result.updated}), skipped=#{result.skipped}"
  end

  desc "Import geochemical reference assays from an EarthChem CSV/TSV file"
  task :import_earthchem, [ :path ] => :environment do |_task, args|
    path = args[:path]
    raise ArgumentError, "Usage: rake geochem:import_earthchem[path/to/file.csv]" if path.blank?
    raise Errno::ENOENT, "File not found: #{path}" unless File.exist?(path)

    result = Ingestion::EarthchemCsvImporter.new(path).call
    puts "EarthChem import complete: imported=#{result.imported} (created=#{result.created}, updated=#{result.updated}), skipped=#{result.skipped}"
  end

  desc "Fetch and bulk-import USGS ScienceBase NGDB assays for a region preset (WA, OR, PNW, CA) or bbox (min_lat,min_lng,max_lat,max_lng)"
  task :fetch_usgs_region, [ :region_or_bbox ] => :environment do |_task, args|
    region = args[:region_or_bbox].presence || ENV["REGION"].presence || "PNW"
    result = Ingestion::UsgsSciencebaseFetcher.call(region: region)
    puts "USGS ScienceBase fetch (#{region}) complete: files=#{result.files_processed}, matched_rows=#{result.matched_rows}, filtered_out=#{result.filtered_out_rows}, imported=#{result.imported} (created=#{result.created}, updated=#{result.updated}), skipped=#{result.skipped}"
  end

  desc "Import USGS Data Series 801 C-horizon soil geochemistry and XRD mineralogy CSV/TSV file"
  task :import_usgs_ds801, [ :path ] => :environment do |_task, args|
    path = args[:path]
    raise ArgumentError, "Usage: rake geochem:import_usgs_ds801[path/to/file.csv]" if path.blank?
    raise Errno::ENOENT, "File not found: #{path}" unless File.exist?(path)

    Ingestion
    unless defined?(Ingestion::UsgsDs801Importer)
      raise NotImplementedError, "Ingestion::UsgsDs801Importer is not loaded in this branch"
    end

    result = Ingestion::UsgsDs801Importer.new(path).call
    puts "USGS DS-801 import complete: imported=#{result.imported} (created=#{result.created}, updated=#{result.updated}), skipped=#{result.skipped}"
  end

  desc "Import hard-rock igneous geochemical reference assays from a GEOROC CSV/TSV export"
  task :import_georoc, [ :path ] => :environment do |_task, args|
    path = args[:path]
    raise ArgumentError, "Usage: rake geochem:import_georoc[path/to/file.csv]" if path.blank?
    raise Errno::ENOENT, "File not found: #{path}" unless File.exist?(path)

    result = Ingestion::GeorocCsvImporter.new(path).call
    puts "GEOROC import complete: imported=#{result.imported} (created=#{result.created}, updated=#{result.updated}), skipped=#{result.skipped}"
  end

  desc "Import Western North America volcanic reference assays from a NAVDAT CSV/TSV export"
  task :import_navdat, [ :path ] => :environment do |_task, args|
    path = args[:path]
    raise ArgumentError, "Usage: rake geochem:import_navdat[path/to/file.csv]" if path.blank?
    raise Errno::ENOENT, "File not found: #{path}" unless File.exist?(path)

    result = Ingestion::NavdatCsvImporter.new(path).call
    puts "NAVDAT import complete: imported=#{result.imported} (created=#{result.created}, updated=#{result.updated}), skipped=#{result.skipped}"
  end

  desc "Idempotently seed curated PNW & Western NA hard-rock ceramic mineral occurrences"
  task :seed_mineral_occurrences, [ :path ] => :environment do |_task, args|
    Ingestion
    unless defined?(Ingestion::MineralOccurrenceSeeder)
      raise NotImplementedError, "Ingestion::MineralOccurrenceSeeder is not loaded in this branch"
    end

    result = args[:path].present? ? Ingestion::MineralOccurrenceSeeder.call(args[:path]) : Ingestion::MineralOccurrenceSeeder.call
    if result.respond_to?(:imported)
      puts "Mineral occurrences seed complete: imported=#{result.imported} (created=#{result.created}, updated=#{result.updated}), skipped=#{result.skipped}, total_mineral_occurrences=#{MineralOccurrence.count}"
    elsif result.is_a?(Hash)
      summary = result.map { |k, v| "#{k}=#{v}" }.join(", ")
      puts "Mineral occurrences seed complete: #{summary}, total_mineral_occurrences=#{MineralOccurrence.count}"
    else
      puts "Mineral occurrences seed complete: total_mineral_occurrences=#{MineralOccurrence.count}"
    end
  end
end
