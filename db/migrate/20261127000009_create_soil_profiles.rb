# frozen_string_literal: true

class CreateSoilProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :soil_profiles do |t|
      t.string :mukey, null: false
      t.string :map_unit_name
      t.string :component_name
      t.decimal :component_percent, precision: 5, scale: 2
      t.jsonb :horizons, default: [], null: false
      t.decimal :max_clay_pct, precision: 5, scale: 2
      t.decimal :max_plasticity_index, precision: 5, scale: 2
      t.decimal :max_caco3_pct, precision: 5, scale: 2
      t.st_point :location, geographic: true, srid: 4326
      t.datetime :fetched_at

      t.timestamps
    end

    add_index :soil_profiles, :mukey, unique: true
    add_index :soil_profiles, :location, using: :gist

    add_reference :user_samples, :soil_profile, null: true, foreign_key: true
  end
end
