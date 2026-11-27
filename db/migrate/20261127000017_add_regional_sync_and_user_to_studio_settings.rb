# frozen_string_literal: true

class AddRegionalSyncAndUserToStudioSettings < ActiveRecord::Migration[8.1]
  def change
    add_reference :studio_settings, :user, null: true, foreign_key: true
    add_column :studio_settings, :regional_sync_status, :string, default: "idle", null: false
    add_column :studio_settings, :regional_synced_at, :datetime
    add_column :studio_settings, :regional_sync_summary, :string
  end
end
