# frozen_string_literal: true

seed_csv = Rails.root.join("db/seeds/sample_assays.csv")
result = Ingestion::UsgsCsvImporter.new(seed_csv).call

puts "Seeded reference assays from #{seed_csv.basename}: " \
     "imported=#{result.imported} (created=#{result.created}, updated=#{result.updated}), " \
     "skipped=#{result.skipped}, total_reference_assays=#{ReferenceAssay.count}"
