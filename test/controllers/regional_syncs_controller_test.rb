# frozen_string_literal: true

require "test_helper"

class RegionalSyncsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    StudioSetting.delete_all
    clear_enqueued_jobs
  end

  test "POST /regional_sync queues RegionalAtlasSyncJob and replaces #regional_sync_card via Turbo Stream" do
    setting = StudioSetting.current

    assert_enqueued_with(
      job: RegionalAtlasSyncJob,
      args: [ setting.id, { lat: 47.2529, lng: -122.4443, radius_km: 300 } ]
    ) do
      post regional_sync_path,
        params: { lat: "47.2529", lng: "-122.4443", radius_km: "300" },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, '<turbo-stream action="replace" target="regional_sync_card">'
    assert_includes response.body, 'data-regional-sync-status="queued"'
    assert_includes response.body, "Queued"
    assert_includes response.body, "Hydrate Regional Atlas"
    assert_includes response.body, 'selected="selected" value="300"'

    setting.reload
    assert_equal "queued", setting.regional_sync_status
    assert_includes setting.regional_sync_summary, "300 km"
  end

  test "POST /regional_sync falls back to StudioSetting defaults and redirects for HTML requests" do
    setting = StudioSetting.current
    setting.update!(default_lat: 35.6870, default_lng: -105.9378)

    assert_enqueued_with(
      job: RegionalAtlasSyncJob,
      args: [ setting.id, { lat: 35.687, lng: -105.9378, radius_km: 150 } ]
    ) do
      post regional_sync_path
    end

    assert_redirected_to setup_path(step: 4)
    assert_includes flash[:notice], "150 km"

    setting.reload
    assert_equal "queued", setting.regional_sync_status
  end

  test "POST /regional_sync supports JSON responses and clamps radius_km" do
    setting = StudioSetting.current

    assert_enqueued_with(
      job: RegionalAtlasSyncJob,
      args: [ setting.id, { lat: setting.default_lat.to_f, lng: setting.default_lng.to_f, radius_km: 500 } ]
    ) do
      post regional_sync_path(format: :json), params: { radius_km: 999 }
    end

    assert_response :accepted
    body = JSON.parse(response.body)
    assert_equal "queued", body["status"]
    assert_equal 500, body["radius_km"]
  end

  test "POST /regional_sync returns 422 and does not enqueue job on invalid coordinates" do
    assert_no_enqueued_jobs only: RegionalAtlasSyncJob do
      post regional_sync_path,
        params: { lat: "not-a-lat", lng: "-122.4443" },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "regional_sync_card"
    assert_includes response.body, "Valid latitude"
  end
end
