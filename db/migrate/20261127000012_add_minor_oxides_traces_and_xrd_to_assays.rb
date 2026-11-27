# frozen_string_literal: true

class AddMinorOxidesTracesAndXrdToAssays < ActiveRecord::Migration[8.1]
  def change
    change_table :reference_assays, bulk: true do |t|
      t.jsonb :minor_oxides, default: {}, null: false
      t.jsonb :trace_elements_ppm, default: {}, null: false
      t.jsonb :xrd_mineralogy, default: {}, null: false
      t.string :sample_media
    end
    add_index :reference_assays, :sample_media

    change_table :assay_results, bulk: true do |t|
      t.jsonb :minor_oxides, default: {}, null: false
      t.jsonb :trace_elements_ppm, default: {}, null: false
      t.string :analysis_method
    end
  end
end
