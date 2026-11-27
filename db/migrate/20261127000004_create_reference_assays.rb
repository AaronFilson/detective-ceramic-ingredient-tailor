# frozen_string_literal: true

class CreateReferenceAssays < ActiveRecord::Migration[8.1]
  def change
    create_table :reference_assays do |t|
      t.string :source, null: false
      t.string :external_id
      t.string :rock_type
      t.st_point :location, geographic: true, srid: 4326
      t.jsonb :oxides, default: {}, null: false
      t.jsonb :raw_metadata, default: {}, null: false

      t.timestamps
    end

    add_index :reference_assays, :external_id
    add_index :reference_assays, %i[source external_id], unique: true
    add_index :reference_assays, :rock_type
    add_index :reference_assays, :location, using: :gist
  end
end
