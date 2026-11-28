# frozen_string_literal: true

class MakeStudioSettingsUserIdUnique < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      DELETE FROM studio_settings a
      USING studio_settings b
      WHERE a.user_id IS NOT NULL
        AND a.user_id = b.user_id
        AND a.id > b.id
    SQL

    remove_index :studio_settings, :user_id, if_exists: true
    add_index :studio_settings, :user_id, unique: true
  end

  def down
    remove_index :studio_settings, :user_id, if_exists: true
    add_index :studio_settings, :user_id
  end
end
