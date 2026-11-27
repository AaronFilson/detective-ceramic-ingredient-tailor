# frozen_string_literal: true

require "test_helper"
require "rake"
require "tempfile"

class GeochemRakeTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks if Rake::Task.tasks.empty?
  end

  test "geochem:import_usgs imports CSV file via rake task" do
    task = Rake::Task["geochem:import_usgs"]
    task.reenable

    Tempfile.create([ "usgs_rake", ".csv" ]) do |f|
      f.write("LAB_ID,LATITUDE,LONGITUDE,ROCK_TYPE,SIO2,AL2O3,FE2O3,LOI\n")
      f.write("RAKE-USGS-1,47.25,-122.44,glacial_clay,60.0,18.0,6.0,6.0\n")
      f.flush

      assert_output(/USGS import complete: imported=1/) do
        task.invoke(f.path)
      end
    end

    assert ReferenceAssay.exists?(source: "usgs_ngdb", external_id: "RAKE-USGS-1")
  end

  test "geochem:import_earthchem imports CSV file via rake task" do
    task = Rake::Task["geochem:import_earthchem"]
    task.reenable

    Tempfile.create([ "earthchem_rake", ".csv" ]) do |f|
      f.write("SAMPLE ID,LATITUDE,LONGITUDE,ROCK NAME,SIO2,AL2O3,FEOT,LOI\n")
      f.write("RAKE-EC-1,46.94,-119.98,basalt,51.0,14.0,12.0,1.0\n")
      f.flush

      assert_output(/EarthChem import complete: imported=1/) do
        task.invoke(f.path)
      end
    end

    assert ReferenceAssay.exists?(source: "earthchem", external_id: "RAKE-EC-1")
  end
end
