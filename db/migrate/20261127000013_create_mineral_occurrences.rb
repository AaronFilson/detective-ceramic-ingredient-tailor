# frozen_string_literal: true

class CreateMineralOccurrences < ActiveRecord::Migration[8.1]
  def change
    create_table :mineral_occurrences do |t|
      t.string :source, null: false
      t.string :external_id
      t.string :name, null: false
      t.jsonb :commodities, default: [], null: false
      t.jsonb :minerals, default: [], null: false
      t.string :deposit_type
      t.st_point :location, geographic: true, srid: 4326
      t.jsonb :raw_metadata, default: {}, null: false

      t.timestamps
    end

    add_index :mineral_occurrences, [ :source, :external_id ], unique: true
    add_index :mineral_occurrences, :location, using: :gist
    add_index :mineral_occurrences, :source
  end
end
