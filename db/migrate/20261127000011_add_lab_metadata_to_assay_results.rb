# frozen_string_literal: true

class AddLabMetadataToAssayResults < ActiveRecord::Migration[8.1]
  def change
    change_table :assay_results, bulk: true do |t|
      t.string :lab_name
      t.string :lab_report_ref
      t.boolean :promoted_to_reference, default: false, null: false
      t.references :reference_assay, null: true, foreign_key: true
    end
  end
end
