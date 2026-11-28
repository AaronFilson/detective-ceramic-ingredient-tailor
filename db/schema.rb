# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_11_27_000017) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "postgis"

  create_table "active_storage_attachments", force: :cascade do |t|
    t.string "name", null: false
    t.string "record_type", null: false
    t.bigint "record_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.string "key", null: false
    t.string "filename", null: false
    t.string "content_type"
    t.text "metadata"
    t.string "service_name", null: false
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.datetime "created_at", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "assay_results", force: :cascade do |t|
    t.bigint "user_sample_id", null: false
    t.integer "source_type", default: 0, null: false
    t.jsonb "oxides", default: {}, null: false
    t.jsonb "oxide_ranges", default: {}, null: false
    t.jsonb "umf_formula", default: {}, null: false
    t.decimal "confidence_score", precision: 4, scale: 3
    t.jsonb "reasoning_log", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "lab_name"
    t.string "lab_report_ref"
    t.boolean "promoted_to_reference", default: false, null: false
    t.bigint "reference_assay_id"
    t.jsonb "minor_oxides", default: {}, null: false
    t.jsonb "trace_elements_ppm", default: {}, null: false
    t.string "analysis_method"
    t.index ["reference_assay_id"], name: "index_assay_results_on_reference_assay_id"
    t.index ["user_sample_id"], name: "index_assay_results_on_user_sample_id"
  end

  create_table "field_observations", force: :cascade do |t|
    t.bigint "user_sample_id", null: false
    t.integer "vinegar_fizz", default: 0
    t.integer "slaking_behavior"
    t.integer "plasticity"
    t.string "raw_color"
    t.string "fired_cone"
    t.string "fired_color"
    t.integer "melt_state"
    t.decimal "shrinkage_percent", precision: 5, scale: 2
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.decimal "water_of_plasticity", precision: 5, scale: 2
    t.decimal "drying_shrinkage_percent", precision: 5, scale: 2
    t.decimal "firing_shrinkage_percent", precision: 5, scale: 2
    t.decimal "boiling_water_absorption_percent", precision: 5, scale: 2
    t.index ["user_sample_id"], name: "index_field_observations_on_user_sample_id"
  end

  create_table "geologic_units", force: :cascade do |t|
    t.integer "macrostrat_id", null: false
    t.string "name"
    t.string "strat_name"
    t.jsonb "lithology", default: {}, null: false
    t.string "age"
    t.geometry "boundary", limit: {:srid=>4326, :type=>"geometry"}
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["boundary"], name: "index_geologic_units_on_boundary", using: :gist
    t.index ["macrostrat_id"], name: "index_geologic_units_on_macrostrat_id", unique: true
  end

  create_table "mineral_occurrences", force: :cascade do |t|
    t.string "source", null: false
    t.string "external_id"
    t.string "name", null: false
    t.jsonb "commodities", default: [], null: false
    t.jsonb "minerals", default: [], null: false
    t.string "deposit_type"
    t.geography "location", limit: {:srid=>4326, :type=>"st_point", :geographic=>true}
    t.jsonb "raw_metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["location"], name: "index_mineral_occurrences_on_location", using: :gist
    t.index ["source", "external_id"], name: "index_mineral_occurrences_on_source_and_external_id", unique: true
    t.index ["source"], name: "index_mineral_occurrences_on_source"
  end

  create_table "reference_assays", force: :cascade do |t|
    t.string "source", null: false
    t.string "external_id"
    t.string "rock_type"
    t.geography "location", limit: {:srid=>4326, :type=>"st_point", :geographic=>true}
    t.jsonb "oxides", default: {}, null: false
    t.jsonb "raw_metadata", default: {}, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "minor_oxides", default: {}, null: false
    t.jsonb "trace_elements_ppm", default: {}, null: false
    t.jsonb "xrd_mineralogy", default: {}, null: false
    t.string "sample_media"
    t.index ["external_id"], name: "index_reference_assays_on_external_id"
    t.index ["location"], name: "index_reference_assays_on_location", using: :gist
    t.index ["rock_type"], name: "index_reference_assays_on_rock_type"
    t.index ["sample_media"], name: "index_reference_assays_on_sample_media"
    t.index ["source", "external_id"], name: "index_reference_assays_on_source_and_external_id", unique: true
  end

  create_table "soil_profiles", force: :cascade do |t|
    t.string "mukey", null: false
    t.string "map_unit_name"
    t.string "component_name"
    t.decimal "component_percent", precision: 5, scale: 2
    t.jsonb "horizons", default: [], null: false
    t.decimal "max_clay_pct", precision: 5, scale: 2
    t.decimal "max_plasticity_index", precision: 5, scale: 2
    t.decimal "max_caco3_pct", precision: 5, scale: 2
    t.geography "location", limit: {:srid=>4326, :type=>"st_point", :geographic=>true}
    t.datetime "fetched_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "source", default: "usda_ssurgo", null: false
    t.decimal "soil_ph", precision: 4, scale: 2
    t.decimal "cec", precision: 6, scale: 2
    t.decimal "organic_carbon", precision: 6, scale: 2
    t.index ["location"], name: "index_soil_profiles_on_location", using: :gist
    t.index ["mukey"], name: "index_soil_profiles_on_mukey", unique: true
    t.index ["source"], name: "index_soil_profiles_on_source"
  end

  create_table "solid_queue_batch_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "batch_id", null: false
    t.datetime "created_at", null: false
    t.index ["batch_id"], name: "index_solid_queue_batch_executions_on_batch_id"
    t.index ["job_id"], name: "index_solid_queue_batch_executions_on_job_id", unique: true
  end

  create_table "solid_queue_batches", force: :cascade do |t|
    t.string "active_job_batch_id"
    t.string "description"
    t.text "on_finish"
    t.text "on_success"
    t.text "on_failure"
    t.text "metadata"
    t.integer "total_jobs", default: 0, null: false
    t.integer "completed_jobs", default: 0, null: false
    t.integer "failed_jobs", default: 0, null: false
    t.datetime "enqueued_at"
    t.datetime "finished_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_batch_id"], name: "index_solid_queue_batches_on_active_job_batch_id", unique: true
    t.index ["finished_at"], name: "index_solid_queue_batches_on_finished_at"
  end

  create_table "solid_queue_blocked_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.string "concurrency_key", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.index ["concurrency_key", "priority", "job_id"], name: "index_solid_queue_blocked_executions_for_release"
    t.index ["expires_at", "concurrency_key"], name: "index_solid_queue_blocked_executions_for_maintenance"
    t.index ["job_id"], name: "index_solid_queue_blocked_executions_on_job_id", unique: true
  end

  create_table "solid_queue_claimed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.bigint "process_id"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_claimed_executions_on_job_id", unique: true
    t.index ["process_id", "job_id"], name: "index_solid_queue_claimed_executions_on_process_id_and_job_id"
  end

  create_table "solid_queue_failed_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.text "error"
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_failed_executions_on_job_id", unique: true
  end

  create_table "solid_queue_jobs", force: :cascade do |t|
    t.string "queue_name", null: false
    t.string "class_name", null: false
    t.text "arguments"
    t.integer "priority", default: 0, null: false
    t.string "active_job_id"
    t.datetime "scheduled_at"
    t.datetime "finished_at"
    t.string "concurrency_key"
    t.bigint "batch_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["active_job_id"], name: "index_solid_queue_jobs_on_active_job_id"
    t.index ["batch_id"], name: "index_solid_queue_jobs_on_batch_id"
    t.index ["class_name"], name: "index_solid_queue_jobs_on_class_name"
    t.index ["finished_at"], name: "index_solid_queue_jobs_on_finished_at"
    t.index ["queue_name", "finished_at"], name: "index_solid_queue_jobs_for_filtering"
    t.index ["scheduled_at", "finished_at"], name: "index_solid_queue_jobs_for_alerting"
  end

  create_table "solid_queue_pauses", force: :cascade do |t|
    t.string "queue_name", null: false
    t.datetime "created_at", null: false
    t.index ["queue_name"], name: "index_solid_queue_pauses_on_queue_name", unique: true
  end

  create_table "solid_queue_processes", force: :cascade do |t|
    t.string "kind", null: false
    t.datetime "last_heartbeat_at", null: false
    t.bigint "supervisor_id"
    t.integer "pid", null: false
    t.string "hostname"
    t.text "metadata"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.index ["last_heartbeat_at"], name: "index_solid_queue_processes_on_last_heartbeat_at"
    t.index ["name", "supervisor_id"], name: "index_solid_queue_processes_on_name_and_supervisor_id", unique: true
    t.index ["supervisor_id"], name: "index_solid_queue_processes_on_supervisor_id"
  end

  create_table "solid_queue_ready_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_ready_executions_on_job_id", unique: true
    t.index ["priority", "job_id"], name: "index_solid_queue_poll_all"
    t.index ["queue_name", "priority", "job_id"], name: "index_solid_queue_poll_by_queue"
  end

  create_table "solid_queue_recurring_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "task_key", null: false
    t.datetime "run_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_recurring_executions_on_job_id", unique: true
    t.index ["task_key", "run_at"], name: "index_solid_queue_recurring_executions_on_task_key_and_run_at", unique: true
  end

  create_table "solid_queue_recurring_tasks", force: :cascade do |t|
    t.string "key", null: false
    t.string "schedule", null: false
    t.string "command", limit: 2048
    t.string "class_name"
    t.text "arguments"
    t.string "queue_name"
    t.integer "priority", default: 0
    t.boolean "static", default: true, null: false
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["key"], name: "index_solid_queue_recurring_tasks_on_key", unique: true
    t.index ["static"], name: "index_solid_queue_recurring_tasks_on_static"
  end

  create_table "solid_queue_scheduled_executions", force: :cascade do |t|
    t.bigint "job_id", null: false
    t.string "queue_name", null: false
    t.integer "priority", default: 0, null: false
    t.datetime "scheduled_at", null: false
    t.datetime "created_at", null: false
    t.index ["job_id"], name: "index_solid_queue_scheduled_executions_on_job_id", unique: true
    t.index ["scheduled_at", "priority", "job_id"], name: "index_solid_queue_dispatch_all"
  end

  create_table "solid_queue_semaphores", force: :cascade do |t|
    t.string "key", null: false
    t.integer "value", default: 1, null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_solid_queue_semaphores_on_expires_at"
    t.index ["key", "value"], name: "index_solid_queue_semaphores_on_key_and_value"
    t.index ["key"], name: "index_solid_queue_semaphores_on_key", unique: true
  end

  create_table "studio_settings", force: :cascade do |t|
    t.string "studio_name", default: "", null: false
    t.string "home_region_label", default: "Pacific Northwest", null: false
    t.decimal "default_lat", precision: 8, scale: 5, default: "47.2529", null: false
    t.decimal "default_lng", precision: 8, scale: 5, default: "-122.4443", null: false
    t.integer "default_zoom", default: 8, null: false
    t.string "default_material_category", default: "wild_clay", null: false
    t.string "default_fired_cone", default: "6", null: false
    t.string "default_blend_surface", default: "gloss", null: false
    t.boolean "show_macrostrat_layer", default: true, null: false
    t.boolean "show_reference_assays_layer", default: true, null: false
    t.boolean "show_mineral_occurrences_layer", default: true, null: false
    t.boolean "has_pxrf_workflow", default: false, null: false
    t.string "preferred_export_target", default: "both", null: false
    t.string "glazecalc_base_url", default: "https://glazecalc.com", null: false
    t.datetime "onboarding_completed_at"
    t.datetime "onboarding_skipped_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.string "regional_sync_status", default: "idle", null: false
    t.datetime "regional_synced_at"
    t.string "regional_sync_summary"
    t.index ["user_id"], name: "index_studio_settings_on_user_id"
  end

  create_table "user_samples", force: :cascade do |t|
    t.bigint "user_id"
    t.string "title", null: false
    t.integer "material_category", default: 0, null: false
    t.geography "location", limit: {:srid=>4326, :type=>"st_point", :geographic=>true}
    t.bigint "geologic_unit_id"
    t.text "notes"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.bigint "soil_profile_id"
    t.index ["geologic_unit_id"], name: "index_user_samples_on_geologic_unit_id"
    t.index ["location"], name: "index_user_samples_on_location", using: :gist
    t.index ["soil_profile_id"], name: "index_user_samples_on_soil_profile_id"
    t.index ["user_id"], name: "index_user_samples_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.string "email"
    t.string "name"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "assay_results", "reference_assays"
  add_foreign_key "assay_results", "user_samples"
  add_foreign_key "field_observations", "user_samples"
  add_foreign_key "solid_queue_batch_executions", "solid_queue_batches", column: "batch_id", on_delete: :cascade
  add_foreign_key "solid_queue_batch_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_blocked_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_claimed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_failed_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_ready_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_recurring_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "solid_queue_scheduled_executions", "solid_queue_jobs", column: "job_id", on_delete: :cascade
  add_foreign_key "studio_settings", "users"
  add_foreign_key "user_samples", "geologic_units"
  add_foreign_key "user_samples", "soil_profiles"
  add_foreign_key "user_samples", "users"
end
