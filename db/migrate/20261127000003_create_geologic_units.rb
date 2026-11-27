# frozen_string_literal: true

class CreateGeologicUnits < ActiveRecord::Migration[8.1]
  def change
    create_table :geologic_units do |t|
      t.integer :macrostrat_id, null: false
      t.string :name
      t.string :strat_name
      t.jsonb :lithology, default: {}, null: false
      t.string :age
      t.geometry :boundary, srid: 4326

      t.timestamps
    end

    add_index :geologic_units, :macrostrat_id, unique: true
    add_index :geologic_units, :boundary, using: :gist
  end
end
