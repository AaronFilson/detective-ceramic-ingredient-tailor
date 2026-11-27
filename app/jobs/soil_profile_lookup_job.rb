# frozen_string_literal: true

class SoilProfileLookupJob < ApplicationJob
  queue_as :default

  def perform(user_sample_id)
    sample = UserSample.find_by(id: user_sample_id)
    return nil if sample.nil?
    return nil if sample.latitude.nil? || sample.longitude.nil?

    profile = Clients::UsdaSsurgoClient.lookup(lat: sample.latitude, lng: sample.longitude)
    profile ||= Clients::IsricSoilgridsClient.lookup(lat: sample.latitude, lng: sample.longitude)
    return nil if profile.nil?

    profile_changed = sample.soil_profile_id != profile.id
    sample.update!(soil_profile: profile) if profile_changed

    if profile_changed &&
        defined?(Inference::SampleEstimatorService) &&
        sample.latest_verified_lab_assay.nil?
      Inference::SampleEstimatorService.call(sample)
    end

    profile
  end
end
