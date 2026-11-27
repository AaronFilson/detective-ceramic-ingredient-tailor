# frozen_string_literal: true

seed_csv = Rails.root.join("db/seeds/sample_assays.csv")
result = Ingestion::UsgsCsvImporter.new(seed_csv).call

puts "Seeded reference assays from #{seed_csv.basename}: " \
     "imported=#{result.imported} (created=#{result.created}, updated=#{result.updated}), " \
     "skipped=#{result.skipped}, total_reference_assays=#{ReferenceAssay.count}"

mineral_csv = Rails.root.join("db/seeds/pnw_mineral_occurrences.csv")
if defined?(Ingestion::MineralOccurrenceSeeder) && File.exist?(mineral_csv)
  mineral_result = Ingestion::MineralOccurrenceSeeder.call
  if mineral_result.respond_to?(:imported)
    puts "Seeded mineral occurrences from #{mineral_csv.basename}: " \
         "imported=#{mineral_result.imported} (created=#{mineral_result.created}, updated=#{mineral_result.updated}), " \
         "skipped=#{mineral_result.skipped}, total_mineral_occurrences=#{MineralOccurrence.count}"
  else
    puts "Seeded mineral occurrences from #{mineral_csv.basename}: " \
         "total_mineral_occurrences=#{MineralOccurrence.count}"
  end
end

ds801_csv = Rails.root.join("db/seeds/sample_ds801_soils.csv")
if defined?(Ingestion::UsgsDs801Importer) && File.exist?(ds801_csv)
  ds801_result = Ingestion::UsgsDs801Importer.new(ds801_csv).call
  puts "Seeded USGS DS-801 soil assays from #{ds801_csv.basename}: " \
       "imported=#{ds801_result.imported} (created=#{ds801_result.created}, updated=#{ds801_result.updated}), " \
       "skipped=#{ds801_result.skipped}, total_reference_assays=#{ReferenceAssay.count}"
end
