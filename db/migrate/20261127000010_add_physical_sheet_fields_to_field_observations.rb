# frozen_string_literal: true

class AddPhysicalSheetFieldsToFieldObservations < ActiveRecord::Migration[8.1]
  def change
    change_table :field_observations, bulk: true do |t|
      t.decimal :water_of_plasticity, precision: 5, scale: 2
      t.decimal :drying_shrinkage_percent, precision: 5, scale: 2
      t.decimal :firing_shrinkage_percent, precision: 5, scale: 2
      t.decimal :boiling_water_absorption_percent, precision: 5, scale: 2
    end
  end
end
