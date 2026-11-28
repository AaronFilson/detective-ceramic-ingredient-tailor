# frozen_string_literal: true

require "test_helper"

class UserAndApiTokenTest < ActiveSupport::TestCase
  EARTH_RADIUS_KM = 6371.0

  test "User normalizes email, validates format/uniqueness, authenticates password, and expires reset tokens on password change" do
    user = User.new(
      name: "Puget Potter",
      email: "  Potter@Studio.Example  ",
      password: "kiln-stoneware-6",
      password_confirmation: "kiln-stoneware-6"
    )
    assert user.save(context: :registration)
    assert_equal "potter@studio.example", user.email
    assert user.member?
    assert user.authenticate("kiln-stoneware-6")
    assert_not user.authenticate("wrong-password")

    dup = User.new(email: "POTTER@studio.example", password: "another-password-1")
    assert_not dup.valid?
    assert_includes dup.errors[:email], "has already been taken"

    bad_email = User.new(email: "not-an-email", password: "another-password-1")
    assert_not bad_email.valid?
    assert bad_email.errors[:email].any?

    blank_pw = User.new(email: "newpotter@studio.example")
    assert_not blank_pw.valid?(:registration)
    assert_includes blank_pw.errors[:password], "can't be blank"

    token = user.generate_token_for(:password_reset)
    assert_equal user, User.find_by_token_for(:password_reset, token)

    user.update!(password: "cone-10-reduction", password_confirmation: "cone-10-reduction")
    assert_nil User.find_by_token_for(:password_reset, token)
  end

  test "ApiToken.issue!, authenticate, and revoke! manage hashed personal Bearer tokens" do
    user = User.create!(
      name: "Token Potter",
      email: "tokens@studio.example",
      password: "secure-password-10"
    )

    record, plaintext = ApiToken.issue!(user: user, name: "Glazecalc Desktop")
    assert plaintext.start_with?("dcit_")
    assert_equal plaintext[0, 12], record.token_prefix
    assert_not_equal plaintext, record.token_digest
    assert_equal Digest::SHA256.hexdigest(plaintext), record.token_digest
    assert_nil record.last_used_at
    assert_not record.revoked?

    found_raw = ApiToken.authenticate(plaintext)
    assert_equal record, found_raw
    assert_not_nil record.reload.last_used_at

    found_bearer = ApiToken.authenticate("Bearer #{plaintext}")
    assert_equal record, found_bearer
    assert_equal user, found_bearer.user

    assert_nil ApiToken.authenticate("Bearer invalid_prefix_12345")
    assert_nil ApiToken.authenticate("Bearer dcit_000000000000000000000000000000000000000000000000")

    record.revoke!
    assert record.revoked?
    assert_not_includes ApiToken.active, record
    assert_nil ApiToken.authenticate("Bearer #{plaintext}")
  end

  test "UserSample.for_owner and claim_guest! isolate tenants and claim guest sandbox samples" do
    user_a = User.create!(email: "usera@studio.example", password: "password-alpha-1")
    user_b = User.create!(email: "userb@studio.example", password: "password-bravo-2")

    guest_a_sample = UserSample.create!(title: "Guest A Creek Clay", guest_token: "guest_tok_a")
    guest_b_sample = UserSample.create!(title: "Guest B Basalt", guest_token: "guest_tok_b")
    user_b_sample = UserSample.create!(title: "User B Wood Ash", user: user_b)

    guest_a_visible = UserSample.for_owner(user: nil, guest_token: "guest_tok_a")
    assert_includes guest_a_visible, guest_a_sample
    assert_not_includes guest_a_visible, guest_b_sample
    assert_not_includes guest_a_visible, user_b_sample

    claimed_count = UserSample.claim_guest!(guest_token: "guest_tok_a", user: user_a)
    assert_equal 1, claimed_count

    guest_a_sample.reload
    assert_equal user_a.id, guest_a_sample.user_id
    assert_nil guest_a_sample.guest_token

    assert_equal "guest_tok_b", guest_b_sample.reload.guest_token
    assert_equal user_b.id, user_b_sample.reload.user_id

    user_a_visible = UserSample.for_owner(user: user_a, guest_token: nil)
    assert_equal [ guest_a_sample.id ], user_a_visible.pluck(:id)
  end

  test "StudioSetting.for_context and claim_guest! adopt unclaimed singleton once and isolate subsequent guests and users" do
    StudioSetting.delete_all

    seeded = StudioSetting.current
    seeded.complete_onboarding!(studio_name: "Preseeded Studio")
    assert_nil seeded.user_id
    assert_nil seeded.guest_token

    guest_1_setting = StudioSetting.for_context(user: nil, guest_token: "guest_1")
    assert_equal seeded.id, guest_1_setting.id
    assert_equal "guest_1", guest_1_setting.reload.guest_token

    guest_2_setting = StudioSetting.for_context(user: nil, guest_token: "guest_2")
    assert_not_equal guest_1_setting.id, guest_2_setting.id
    assert_equal "guest_2", guest_2_setting.guest_token
    assert_equal "", guest_2_setting.studio_name

    user = User.create!(email: "claimer@studio.example", password: "password-claim-1")
    StudioSetting.claim_guest!(guest_token: "guest_1", user: user)

    guest_1_setting.reload
    assert_equal user.id, guest_1_setting.user_id
    assert_nil guest_1_setting.guest_token
    assert_equal "Preseeded Studio", StudioSetting.for_context(user: user, guest_token: nil).studio_name
  end

  test "ReferenceAssay.fuzz_coordinates offsets coordinates deterministically within ~1.5 to 2.5 km" do
    [
      [ 47.2529, -122.4443, "sample-101" ],
      [ 35.6870, -105.9378, "sample-202" ],
      [ 35.0116, 135.7681, "sample-303" ]
    ].each do |lat, lng, seed_key|
      fuzzed_lat, fuzzed_lng = ReferenceAssay.fuzz_coordinates(lat, lng, seed_key: seed_key)
      repeat_lat, repeat_lng = ReferenceAssay.fuzz_coordinates(lat, lng, seed_key: seed_key)

      assert_equal [ fuzzed_lat, fuzzed_lng ], [ repeat_lat, repeat_lng ]

      dist_km = haversine_km(lat, lng, fuzzed_lat, fuzzed_lng)
      assert dist_km.between?(1.5, 2.5), "Expected fuzzed offset #{dist_km.round(3)} km to be within 1.5..2.5 km"
    end

    other_lat, other_lng = ReferenceAssay.fuzz_coordinates(47.2529, -122.4443, seed_key: "sample-999")
    first_lat, first_lng = ReferenceAssay.fuzz_coordinates(47.2529, -122.4443, seed_key: "sample-101")
    assert_not_equal [ first_lat, first_lng ], [ other_lat, other_lng ]

    invalid = ReferenceAssay.new(source: "community_verified_xrf", coordinate_privacy: "secret")
    assert_not invalid.valid?
    assert invalid.errors[:coordinate_privacy].any?
  end

  private

  def haversine_km(lat1, lng1, lat2, lng2)
    rad = Math::PI / 180.0
    dlat = (lat2 - lat1) * rad
    dlng = (lng2 - lng1) * rad
    a = Math.sin(dlat / 2.0)**2 +
        Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dlng / 2.0)**2
    2.0 * EARTH_RADIUS_KM * Math.atan2(Math.sqrt(a), Math.sqrt(1.0 - a))
  end
end
