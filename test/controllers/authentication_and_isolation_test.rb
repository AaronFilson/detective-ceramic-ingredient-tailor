# frozen_string_literal: true

require "test_helper"

class AuthenticationAndIsolationTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  setup do
    StudioSetting.delete_all
    stub_external_geochemical_apis
  end

  test "guest sandbox creates samples and setup, claims them on sign-up, isolates tenants, and claims new guest work on sign-in" do
    # 1. Guest visits workbench and configures StudioSetting + creates 2 samples
    get root_path
    assert_response :success
    assert_includes response.body, "Guest Sandbox"
    assert_includes response.body, "Sign In"

    patch setup_path, params: {
      studio_setting: {
        studio_name: "Vashon Island Clayworks",
        home_region_label: "Pacific Northwest",
        default_lat: "47.4473",
        default_lng: "-122.4598",
        default_zoom: "9",
        default_material_category: "wild_clay",
        default_fired_cone: "10",
        default_blend_surface: "matte",
        preferred_export_target: "both"
      }
    }
    assert_redirected_to root_path

    post samples_path, params: {
      user_sample: {
        title: "Vashon Beach Glacial Clay",
        material_category: "wild_clay",
        latitude: "47.4473",
        longitude: "-122.4598"
      }
    }
    sample_a1 = UserSample.order(:id).last
    assert_redirected_to sample_path(sample_a1)
    assert_nil sample_a1.user_id
    assert sample_a1.guest_token.present?

    post samples_path, params: {
      user_sample: {
        title: "Maury Island Bluff Silt",
        material_category: "crushed_rock",
        latitude: "47.3810",
        longitude: "-122.4290"
      }
    }
    sample_a2 = UserSample.order(:id).last
    assert_redirected_to sample_path(sample_a2)

    # Guest can export their own sandbox sample
    get sample_glazecalc_export_path(sample_a1, format: :json)
    assert_response :success

    # Registration page notes that guest samples will transfer automatically
    get new_registration_path
    assert_response :success
    assert_includes response.body, "2 guest samples ready to claim"

    # 2. Sign up -> claims both guest samples and StudioSetting into User A
    assert_difference -> { User.count }, 1 do
      post registration_path, params: {
        user: {
          name: "Clara Potter",
          email: "clara@vashonclay.example",
          password: "stoneware-password-10",
          password_confirmation: "stoneware-password-10"
        }
      }
    end
    user_a = User.find_by!(email: "clara@vashonclay.example")
    assert_redirected_to root_path
    assert_match(/Claimed 2 guest studio samples/, flash[:notice])

    assert_equal user_a.id, sample_a1.reload.user_id
    assert_nil sample_a1.guest_token
    assert_equal user_a.id, sample_a2.reload.user_id
    assert_nil sample_a2.guest_token
    assert_equal "Vashon Island Clayworks", user_a.reload.studio_setting.studio_name

    follow_redirect!
    assert_includes response.body, "Clara Potter"
    assert_includes response.body, "Sign Out"
    assert_includes response.body, "Vashon Beach Glacial Clay"

    # 3. Sign out -> User B signs up and cannot view, edit, delete, blend, or export User A's samples
    delete session_path
    assert_redirected_to root_path

    post registration_path, params: {
      user: {
        name: "Mateo Glazer",
        email: "mateo@desertglaze.example",
        password: "desert-feldspar-6",
        password_confirmation: "desert-feldspar-6"
      }
    }
    assert_redirected_to root_path

    get root_path
    assert_response :success
    assert_not_includes response.body, "Vashon Beach Glacial Clay"
    assert_not_includes response.body, "Vashon Island Clayworks"

    get sample_path(sample_a1)
    assert_response :not_found

    patch sample_path(sample_a1), params: { user_sample: { title: "Hijacked Title" } }
    assert_response :not_found
    assert_equal "Vashon Beach Glacial Clay", sample_a1.reload.title

    assert_no_difference -> { UserSample.count } do
      delete sample_path(sample_a1)
    end
    assert_response :not_found

    post sample_field_observations_path(sample_a1), params: {
      field_observation: { vinegar_fizz: "vigorous", fired_cone: "6" }
    }
    assert_response :not_found

    get blends_path
    assert_response :success
    assert_not_includes response.body, "Vashon Beach Glacial Clay"

    post blends_path, params: {
      sample_ids: [ sample_a1.id, sample_a2.id ],
      target_cone: "6",
      surface: "gloss"
    }
    assert_response :unprocessable_content

    get sample_glazecalc_export_path(sample_a1, format: :json)
    assert_response :not_found

    get sample_glaze_vault_export_path(sample_a1, format: :json)
    assert_response :not_found

    # 4. Sign out User B -> create a new guest sample -> sign in as User A -> claims new sample into User A
    delete session_path
    assert_redirected_to root_path

    post samples_path, params: {
      user_sample: {
        title: "Point Robinson Driftwood Ash",
        material_category: "wood_ash",
        latitude: "47.3881",
        longitude: "-122.3742"
      }
    }
    guest_ash = UserSample.order(:id).last
    assert_nil guest_ash.user_id
    assert guest_ash.guest_token.present?

    post session_path, params: {
      session: {
        email: "  CLARA@vashonclay.example ",
        password: "stoneware-password-10"
      }
    }
    assert_redirected_to root_path
    assert_match(/Claimed 1 guest studio sample/, flash[:notice])
    assert_equal user_a.id, guest_ash.reload.user_id
    assert_nil guest_ash.guest_token
    assert_equal "Vashon Island Clayworks", user_a.reload.studio_setting.studio_name

    # User A can export their own sample via signed session cookie
    get sample_glazecalc_export_path(sample_a1, format: :json)
    assert_response :success
    assert_equal "Vashon Beach Glacial Clay", JSON.parse(response.body)["name"]
  end

  test "password reset flow emails signed token, updates password, and rejects reused reset token" do
    user = User.create!(
      name: "Reset Potter",
      email: "reset@studio.example",
      password: "old-kiln-password-8",
      password_confirmation: "old-kiln-password-8"
    )

    get new_password_path
    assert_response :success

    assert_emails 1 do
      perform_enqueued_jobs do
        post passwords_path, params: { password: { email: "RESET@studio.example" } }
      end
    end
    assert_redirected_to new_session_path

    mail = ActionMailer::Base.deliveries.last
    assert_equal [ "reset@studio.example" ], mail.to
    body_text = mail.text_part ? mail.text_part.body.decoded : mail.body.decoded
    token = body_text[%r{/passwords/([^/\s"]+)/edit}, 1]
    assert token.present?, "Expected reset email to contain /passwords/:token/edit link"

    get edit_password_path(token)
    assert_response :success
    assert_includes response.body, "reset@studio.example"

    patch password_path(token), params: {
      user: {
        password: "new-reduction-password-10",
        password_confirmation: "new-reduction-password-10"
      }
    }
    assert_redirected_to new_session_path
    assert user.reload.authenticate("new-reduction-password-10")

    # Token is single-use once password salt changes
    get edit_password_path(token)
    assert_redirected_to new_password_path

    post session_path, params: {
      session: {
        email: "reset@studio.example",
        password: "new-reduction-password-10"
      }
    }
    assert_redirected_to root_path
  end

  test "S3 direct-upload signed ActiveStorage::Blob ID string on POST /samples extracts EXIF GPS and auto-pins sample" do
    jpeg_bytes = build_jpeg_with_gps(lat: 46.8523, lng: -121.7603)
    blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new(jpeg_bytes),
      filename: "rainier_outcrop_direct.jpg",
      content_type: "image/jpeg"
    )

    assert_difference -> { UserSample.count }, 1 do
      post samples_path, params: {
        auto_pin_from_photo: "1",
        user_sample: {
          title: "Direct Upload Rainier Outcrop",
          material_category: "wild_clay",
          latitude: "",
          longitude: "",
          outcrop_photos: [ blob.signed_id ]
        }
      }
    end

    created = UserSample.order(:id).last
    assert_redirected_to sample_path(created)
    assert created.outcrop_photos.attached?
    assert_in_delta 46.8523, created.latitude, 0.001
    assert_in_delta(-121.7603, created.longitude, 0.001)
    assert_match(/Pinned coordinates \(46\.8523, -121\.7603\)/, flash[:notice])
  end

  private

  def build_jpeg_with_gps(lat:, lng:)
    lat_ref = lat >= 0 ? "N\x00\x00\x00".b : "S\x00\x00\x00".b
    lng_ref = lng >= 0 ? "E\x00\x00\x00".b : "W\x00\x00\x00".b
    lat_dms = decimal_to_dms_rationals(lat.abs)
    lng_dms = decimal_to_dms_rationals(lng.abs)

    tiff = +"II".b
    tiff << [ 42 ].pack("v") << [ 8 ].pack("V")
    tiff << [ 1 ].pack("v") << [ 0x8825, 4, 1, 26 ].pack("vvVV") << [ 0 ].pack("V")
    tiff << [ 4 ].pack("v")
    tiff << [ 0x0001, 2, 2 ].pack("vvV") << lat_ref
    tiff << [ 0x0002, 5, 3, 80 ].pack("vvVV")
    tiff << [ 0x0003, 2, 2 ].pack("vvV") << lng_ref
    tiff << [ 0x0004, 5, 3, 104 ].pack("vvVV")
    tiff << [ 0 ].pack("V")
    lat_dms.each { |num, den| tiff << [ num, den ].pack("VV") }
    lng_dms.each { |num, den| tiff << [ num, den ].pack("VV") }

    app1_payload = "Exif\x00\x00".b + tiff
    +"\xFF\xD8\xFF\xE1".b + [ app1_payload.bytesize + 2 ].pack("n") + app1_payload + "\xFF\xD9".b
  end

  def decimal_to_dms_rationals(decimal)
    deg = decimal.floor
    rem_min = (decimal - deg) * 60.0
    min = rem_min.floor
    sec = ((rem_min - min) * 60.0 * 10_000).round
    [ [ deg, 1 ], [ min, 1 ], [ sec, 10_000 ] ]
  end

  def stub_external_geochemical_apis
    stub_request(:get, %r{\Ahttps://macrostrat\.org/api/v2/geologic_units/map})
      .to_return(
        status: 200,
        body: { type: "FeatureCollection", features: [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    stub_request(:post, "https://sdmdataaccess.sc.egov.usda.gov/Tabular/post.rest")
      .to_return(
        status: 200,
        body: { Table: [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    stub_request(:get, %r{\Ahttps://rest\.isric\.org/soilgrids/v2\.0/properties/query})
      .to_return(
        status: 200,
        body: { properties: { layers: [] } }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
    stub_request(:get, %r{\Ahttps://mrdata\.usgs\.gov/})
      .to_return(
        status: 200,
        body: { type: "FeatureCollection", features: [] }.to_json,
        headers: { "Content-Type" => "application/json" }
      )
  end
end

class AuthenticationSessionSecurityControllerTest < ActionController::TestCase
  tests SessionsController

  test "open-redirect return_to_after_authenticating falls back to root_path while preserving safe local paths across reset_session" do
    user = User.create!(
      name: "Redirect Potter",
      email: "redirect@studio.example",
      password: "safe-redirect-password-9",
      password_confirmation: "safe-redirect-password-9"
    )

    [ "//evil.example", "/\\evil.example", "https://evil.example/steal" ].each do |malicious_target|
      session[:return_to_after_authenticating] = malicious_target
      post :create, params: {
        session: { email: user.email, password: "safe-redirect-password-9" }
      }
      assert_redirected_to root_path
      delete :destroy
    end

    session[:return_to_after_authenticating] = "/setup?step=4"
    post :create, params: {
      session: { email: user.email, password: "safe-redirect-password-9" }
    }
    assert_redirected_to "/setup?step=4"
  end
end
