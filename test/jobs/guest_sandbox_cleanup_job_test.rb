# frozen_string_literal: true

require "test_helper"
require "stringio"

class GuestSandboxCleanupJobTest < ActiveJob::TestCase
  test "prunes abandoned guest samples, settings, and stale unattached blobs while preserving active and user data" do
    user = User.create!(
      email: "potter-cleanup@example.com",
      name: "Studio Potter",
      password: "password1234"
    )

    stale_guest_sample = UserSample.create!(
      title: "Abandoned Creek Clay",
      material_category: :wild_clay,
      guest_token: "guest-stale-sample"
    )
    stale_obs = stale_guest_sample.field_observations.create!(vinegar_fizz: :slight, raw_color: "Buff")
    stale_guest_sample.update_columns(created_at: 35.days.ago, updated_at: 35.days.ago)

    stale_guest_sample_two = UserSample.create!(
      title: "Abandoned Shale Bank",
      material_category: :crushed_rock,
      guest_token: "guest-stale-sample-2"
    )
    stale_guest_sample_two.update_columns(created_at: 40.days.ago, updated_at: 40.days.ago)

    recent_guest_sample = UserSample.create!(
      title: "Active Guest Clay",
      material_category: :wild_clay,
      guest_token: "guest-recent-sample"
    )
    recent_guest_sample.update_columns(created_at: 5.days.ago, updated_at: 5.days.ago)

    signed_in_old_sample = UserSample.create!(
      user: user,
      title: "Saved Studio Clay",
      material_category: :wild_clay
    )
    signed_in_old_sample.update_columns(created_at: 90.days.ago, updated_at: 90.days.ago)

    stale_guest_setting = StudioSetting.create!(guest_token: "guest-stale-setting")
    stale_guest_setting.update_columns(created_at: 32.days.ago, updated_at: 32.days.ago)

    recent_guest_setting = StudioSetting.create!(guest_token: "guest-recent-setting")
    recent_guest_setting.update_columns(created_at: 3.days.ago, updated_at: 3.days.ago)

    signed_in_old_setting = StudioSetting.create!(user: user)
    signed_in_old_setting.update_columns(created_at: 90.days.ago, updated_at: 90.days.ago)

    stale_unattached_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("stale-orphan-upload"),
      filename: "orphan_old.jpg",
      content_type: "image/jpeg"
    )
    stale_unattached_blob.update_columns(created_at: 50.hours.ago)

    recent_unattached_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("recent-direct-upload"),
      filename: "orphan_recent.jpg",
      content_type: "image/jpeg"
    )
    recent_unattached_blob.update_columns(created_at: 6.hours.ago)

    stats = nil
    assert_enqueued_with(job: ActiveStorage::PurgeJob) do
      stats = GuestSandboxCleanupJob.perform_now
    end

    assert_equal 2, stats[:pruned_samples]
    assert_equal 1, stats[:pruned_settings]
    assert_operator stats[:purged_blobs], :>=, 1

    assert_nil UserSample.find_by(id: stale_guest_sample.id)
    assert_nil UserSample.find_by(id: stale_guest_sample_two.id)
    assert_nil FieldObservation.find_by(id: stale_obs.id)
    assert_not_nil UserSample.find_by(id: recent_guest_sample.id)
    assert_not_nil UserSample.find_by(id: signed_in_old_sample.id)

    assert_nil StudioSetting.find_by(id: stale_guest_setting.id)
    assert_not_nil StudioSetting.find_by(id: recent_guest_setting.id)
    assert_not_nil StudioSetting.find_by(id: signed_in_old_setting.id)

    assert_not_nil ActiveStorage::Blob.find_by(id: recent_unattached_blob.id)
  end
end

class RegionalSyncTileDedupeTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  test "POST /regional_sync deduplicates nearby requests only after RegionalAtlasSyncJob succeeds" do
    original_cache = Rails.cache
    original_env = ENV["TEST_SYNC_DEDUPE"]
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    ENV["TEST_SYNC_DEDUPE"] = "1"

    stub_request(:get, "https://mrdata.usgs.gov/services/mrds")
      .with(query: hash_including("service" => "WFS", "typeName" => "mrds-high"))
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { type: "FeatureCollection", features: [] }.to_json
      )
    stub_request(:get, %r{\Ahttps://www\.sciencebase\.gov/catalog/items})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: { items: [] }.to_json
      )

    tile_key = RegionalAtlasSyncJob.tile_cache_key(lat: 47.2529, lng: -122.4443, radius_km: 150)

    assert_enqueued_with(job: RegionalAtlasSyncJob) do
      post regional_sync_path,
        params: { lat: "47.2529", lng: "-122.4443", radius_km: "150" },
        as: :json
    end
    assert_response :accepted
    assert_equal false, response.parsed_body["deduped"]
    assert_equal "queued", response.parsed_body["status"]
    assert_not Rails.cache.exist?(tile_key), "Controller must not populate tile cache before sync job finishes"

    perform_enqueued_jobs(only: RegionalAtlasSyncJob)
    assert Rails.cache.exist?(tile_key), "Successful sync job must populate tile dedupe cache"

    # Nearby coordinate in Tacoma (rounds to the same 0.5-degree tile & 150 km radius)
    assert_no_enqueued_jobs(only: RegionalAtlasSyncJob) do
      post regional_sync_path,
        params: { lat: "47.2610", lng: "-122.4510", radius_km: "150" },
        as: :json
    end
    assert_response :accepted
    assert_equal true, response.parsed_body["deduped"]
    assert_equal "synced", response.parsed_body["status"]

    # Distant coordinate in Santa Fe, NM (distinct tile -> enqueues job normally)
    assert_enqueued_with(job: RegionalAtlasSyncJob) do
      post regional_sync_path,
        params: { lat: "35.6870", lng: "-105.9378", radius_km: "150" },
        as: :json
    end
    assert_response :accepted
    assert_equal false, response.parsed_body["deduped"]
  ensure
    WebMock.reset!
    Rails.cache = original_cache
    if original_env.nil?
      ENV.delete("TEST_SYNC_DEDUPE")
    else
      ENV["TEST_SYNC_DEDUPE"] = original_env
    end
  end
end
