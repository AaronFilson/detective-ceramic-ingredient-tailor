# frozen_string_literal: true

class AddSourceAndPropertiesToSoilProfiles < ActiveRecord::Migration[8.1]
  def change
    change_table :soil_profiles, bulk: true do |t|
      t.string :source, default: "usda_ssurgo", null: false
      t.decimal :soil_ph, precision: 4, scale: 2
      t.decimal :cec, precision: 6, scale: 2
      t.decimal :organic_carbon, precision: 6, scale: 2
    end
    add_index :soil_profiles, :source
  end
end
