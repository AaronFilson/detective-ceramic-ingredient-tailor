# frozen_string_literal: true

class GuestSandboxCleanupJob < ApplicationJob
  queue_as :default

  GUEST_RETENTION = 30.days
  UNATTACHED_BLOB_RETENTION = 48.hours

  def perform
    cutoff = GUEST_RETENTION.ago
    blob_cutoff = UNATTACHED_BLOB_RETENTION.ago

    pruned_samples = 0
    UserSample
      .where(user_id: nil)
      .where.not(guest_token: nil)
      .where("updated_at < ?", cutoff)
      .find_each(batch_size: 200) do |sample|
        pruned_samples += 1 if sample.destroy
      end

    pruned_settings = StudioSetting
      .where(user_id: nil)
      .where.not(guest_token: nil)
      .where("updated_at < ?", cutoff)
      .delete_all

    purged_blobs = 0
    ActiveStorage::Blob
      .unattached
      .where("active_storage_blobs.created_at < ?", blob_cutoff)
      .find_each do |blob|
        blob.purge_later
        purged_blobs += 1
      end

    Rails.logger.info(
      "[GuestSandboxCleanupJob] pruned_samples=#{pruned_samples} " \
      "pruned_settings=#{pruned_settings} purged_blobs=#{purged_blobs}"
    )

    {
      pruned_samples: pruned_samples,
      pruned_settings: pruned_settings,
      purged_blobs: purged_blobs
    }
  end
end
