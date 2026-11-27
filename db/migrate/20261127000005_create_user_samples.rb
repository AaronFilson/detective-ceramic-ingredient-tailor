# frozen_string_literal: true

class CreateUserSamples < ActiveRecord::Migration[8.1]
  def change
    create_table :user_samples do |t|
      t.references :user, null: true, foreign_key: true
      t.string :title, null: false
      t.integer :material_category, null: false, default: 0
      t.st_point :location, geographic: true, srid: 4326
      t.references :geologic_unit, null: true, foreign_key: true
      t.text :notes

      t.timestamps
    end

    add_index :user_samples, :location, using: :gist
  end
end
