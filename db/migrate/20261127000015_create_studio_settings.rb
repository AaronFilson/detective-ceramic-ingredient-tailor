# frozen_string_literal: true

class CreateStudioSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :studio_settings do |t|
      t.string :studio_name, default: "", null: false
      t.string :home_region_label, default: "Pacific Northwest", null: false
      t.decimal :default_lat, precision: 8, scale: 5, default: 47.2529, null: false
      t.decimal :default_lng, precision: 8, scale: 5, default: -122.4443, null: false
      t.integer :default_zoom, default: 8, null: false
      t.string :default_material_category, default: "wild_clay", null: false
      t.string :default_fired_cone, default: "6", null: false
      t.string :default_blend_surface, default: "gloss", null: false
      t.boolean :show_macrostrat_layer, default: true, null: false
      t.boolean :show_reference_assays_layer, default: true, null: false
      t.boolean :show_mineral_occurrences_layer, default: true, null: false
      t.boolean :has_pxrf_workflow, default: false, null: false
      t.string :preferred_export_target, default: "both", null: false
      t.string :glazecalc_base_url, default: "https://glazecalc.com", null: false
      t.datetime :onboarding_completed_at
      t.datetime :onboarding_skipped_at

      t.timestamps
    end
  end
end
