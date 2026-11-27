# frozen_string_literal: true

class CreateAssayResults < ActiveRecord::Migration[8.1]
  def change
    create_table :assay_results do |t|
      t.references :user_sample, null: false, foreign_key: true
      t.integer :source_type, null: false, default: 0
      t.jsonb :oxides, default: {}, null: false
      t.jsonb :oxide_ranges, default: {}, null: false
      t.jsonb :umf_formula, default: {}, null: false
      t.decimal :confidence_score, precision: 4, scale: 3
      t.jsonb :reasoning_log, default: [], null: false

      t.timestamps
    end
  end
end
