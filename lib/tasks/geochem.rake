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
end
