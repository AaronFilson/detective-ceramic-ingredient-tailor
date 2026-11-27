# frozen_string_literal: true

class CreateFieldObservations < ActiveRecord::Migration[8.1]
  def change
    create_table :field_observations do |t|
      t.references :user_sample, null: false, foreign_key: true
      t.integer :vinegar_fizz, default: 0
      t.integer :slaking_behavior
      t.integer :plasticity
      t.string :raw_color
      t.string :fired_cone
      t.string :fired_color
      t.integer :melt_state
      t.decimal :shrinkage_percent, precision: 5, scale: 2

      t.timestamps
    end
  end
end
