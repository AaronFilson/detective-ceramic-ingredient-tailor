# frozen_string_literal: true

class EnablePostgisExtension < ActiveRecord::Migration[8.1]
  def up
    enable_extension "postgis" unless extension_enabled?("postgis")
  end

  def down
    disable_extension "postgis" if extension_enabled?("postgis")
  end
end
