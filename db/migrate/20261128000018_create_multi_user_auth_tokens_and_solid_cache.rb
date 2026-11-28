# frozen_string_literal: true

class CreateMultiUserAuthTokensAndSolidCache < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :password_digest, :string
    add_column :users, :role, :integer, default: 0, null: false

    create_table :sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.string :ip_address
      t.string :user_agent

      t.timestamps
    end

    create_table :api_tokens do |t|
      t.references :user, null: false, foreign_key: true
      t.string :name, null: false
      t.string :token_prefix, null: false
      t.string :token_digest, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at

      t.timestamps
    end
    add_index :api_tokens, :token_digest, unique: true

    add_column :user_samples, :guest_token, :string
    add_index :user_samples, :guest_token

    add_column :studio_settings, :guest_token, :string
    add_index :studio_settings, :guest_token, unique: true

    add_column :reference_assays, :promoted_by_user_id, :bigint
    add_column :reference_assays, :coordinate_privacy, :string, default: "exact", null: false
    add_index :reference_assays, :promoted_by_user_id
    add_foreign_key :reference_assays, :users, column: :promoted_by_user_id, on_delete: :nullify

    create_table :solid_cache_entries, if_not_exists: true do |t|
      t.binary :key, limit: 1024, null: false
      t.binary :value, limit: 536_870_912, null: false
      t.datetime :created_at, null: false
      t.bigint :key_hash, null: false
      t.integer :byte_size, null: false
    end
    add_index :solid_cache_entries, :byte_size, if_not_exists: true
    add_index :solid_cache_entries, [ :key_hash, :byte_size ], if_not_exists: true
    add_index :solid_cache_entries, :key_hash, unique: true, if_not_exists: true
  end
end
