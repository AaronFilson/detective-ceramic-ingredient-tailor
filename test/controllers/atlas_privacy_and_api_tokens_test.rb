# frozen_string_literal: true

require "test_helper"

class AtlasPrivacyAndApiTokensTest < ActionDispatch::IntegrationTest
  EARTH_RADIUS_KM = 6371.0

  setup do
    StudioSetting.delete_all
    @user_a = User.create!(
      name: "Atlas Potter A",
      email: "pottera@studio.example",
      password: "atlas-password-10",
      password_confirmation: "atlas-password-10"
    )
    @user_b = User.create!(
      name: "Atlas Potter B",
      email: "potterb@studio.example",
      password: "atlas-password-12",
      password_confirmation: "atlas-password-12"
    )

    @sample_a = UserSample.create!(
      user: @user_a,
      title: "Private Creek Wild Clay",
      material_category: :wild_clay,
      latitude: 47.2529,
      longitude: -122.4443
    )
    SamplesController.estimate_sample(@sample_a)

    @sample_b = UserSample.create!(
      user: @user_b,
      title: "Cascade Pegmatite Spar",
      material_category: :crushed_rock,
      latitude: 47.5580,
      longitude: -117.0780
    )
    SamplesController.estimate_sample(@sample_b)
  end

  test "lab assay panel renders dig-site privacy selector defaulting to exact GPS and requires confirmation before Atlas promotion" do
    sign_in_as(@user_a, "atlas-password-10")

    get sample_path(@sample_a)
    assert_response :success
    assert_select "input[type='hidden'][name='lab_assay[privacy_prompt_shown]'][value='1']"
    assert_select "input[type='radio'][name='lab_assay[coordinate_privacy]'][value='exact'][checked]"
    assert_select "input[type='radio'][name='lab_assay[coordinate_privacy]'][value='fuzzed_2km']"
    assert_select "input[type='checkbox'][name='lab_assay[atlas_privacy_confirmed]']"

    # Submitting with promote_to_reference=1 + privacy_prompt_shown=1 WITHOUT confirmation is rejected with 422
    assert_no_difference [ "AssayResult.count", "ReferenceAssay.count" ] do
      post sample_lab_assays_path(@sample_a),
        params: {
          lab_assay: {
            source_type: "verified_lab_xrf",
            lab_name: "WSU GeoAnalytical",
            promote_to_reference: "1",
            privacy_prompt_shown: "1",
            coordinate_privacy: "fuzzed_2km",
            atlas_privacy_confirmed: "0",
            oxides: { "SiO2" => "62.0", "Al2O3" => "18.0", "Fe2O3" => "5.0", "CaO" => "2.0", "K2O" => "3.0", "LOI" => "10.0" }
          }
        },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Please confirm your dig-site coordinate privacy choice"
  end

  test "confirmed exact vs fuzzed_2km Atlas promotion works on both Lab XRF and handheld pXRF while keeping sample GPS exact" do
    sign_in_as(@user_a, "atlas-password-10")

    # 1. Exact GPS promotion on Lab XRF
    assert_difference -> { ReferenceAssay.count }, 1 do
      post sample_lab_assays_path(@sample_a),
        params: {
          lab_assay: {
            source_type: "verified_lab_xrf",
            lab_name: "WSU GeoAnalytical",
            promote_to_reference: "1",
            privacy_prompt_shown: "1",
            coordinate_privacy: "exact",
            atlas_privacy_confirmed: "1",
            oxides: { "SiO2" => "62.0", "Al2O3" => "18.0", "Fe2O3" => "5.0", "CaO" => "2.0", "K2O" => "3.0", "LOI" => "10.0" }
          }
        }
    end
    assert_redirected_to sample_path(@sample_a)

    exact_ref = @sample_a.reload.latest_verified_lab_assay.reference_assay
    assert_equal "exact", exact_ref.coordinate_privacy
    assert_equal @user_a.id, exact_ref.promoted_by_user_id
    assert_in_delta 47.2529, exact_ref.latitude, 0.0001
    assert_in_delta(-122.4443, exact_ref.longitude, 0.0001)

    get sample_path(@sample_a)
    assert_response :success
    exact_pins = JSON.parse(css_select("[data-map-picker-reference-assays-value]").first["data-map-picker-reference-assays-value"])
    exact_pin = exact_pins.find { |p| p["id"] == exact_ref.id }
    assert_not_nil exact_pin
    assert_equal exact_ref.external_id, exact_pin["external_id"]

    # 2. Fuzzed ~2 km promotion on Lab XRF updates ReferenceAssay to deterministic ~2 km offset and omits external_id
    post sample_lab_assays_path(@sample_a),
      params: {
        lab_assay: {
          source_type: "verified_lab_xrf",
          lab_name: "WSU GeoAnalytical",
          promote_to_reference: "1",
          privacy_prompt_shown: "1",
          coordinate_privacy: "fuzzed_2km",
          atlas_privacy_confirmed: "1",
          oxides: { "SiO2" => "62.5", "Al2O3" => "17.5", "Fe2O3" => "5.0", "CaO" => "2.0", "K2O" => "3.0", "LOI" => "10.0" }
        }
      }
    assert_redirected_to sample_path(@sample_a)

    fuzzed_xrf_assay = @sample_a.reload.latest_verified_lab_assay
    fuzzed_ref = fuzzed_xrf_assay.reference_assay.reload
    assert_equal "fuzzed_2km", fuzzed_ref.coordinate_privacy
    assert_equal "fuzzed_2km", fuzzed_ref.raw_metadata["coordinate_privacy"]
    assert_equal @user_a.id, fuzzed_ref.promoted_by_user_id
    assert fuzzed_xrf_assay.reasoning_log.any? { |entry| entry.include?("(fuzzed ~2 km)") }

    offset_km = haversine_km(47.2529, -122.4443, fuzzed_ref.latitude, fuzzed_ref.longitude)
    assert offset_km.between?(1.5, 2.5), "Expected fuzzed XRF ReferenceAssay distance #{offset_km.round(3)} km in 1.5..2.5 km"

    get sample_path(@sample_a)
    assert_response :success
    fuzzed_pins = JSON.parse(css_select("[data-map-picker-reference-assays-value]").first["data-map-picker-reference-assays-value"])
    fuzzed_pin = fuzzed_pins.find { |p| p["id"] == fuzzed_ref.id }
    assert_not_nil fuzzed_pin
    assert_nil fuzzed_pin["external_id"], "fuzzed_2km map payload must never expose internal sample external_id"

    # Private UserSample coordinates remain exact
    assert_in_delta 47.2529, @sample_a.reload.latitude, 0.0001
    assert_in_delta(-122.4443, @sample_a.longitude, 0.0001)

    # 3. Fuzzed ~2 km promotion on Handheld pXRF CSV
    pxrf_csv = "Sample,Si (%),Al (%),Fe (%),Ca (%),K (%),Rb (ppm)\nPXRF-PRIV,29.5,9.4,2.8,1.3,2.9,210\n"
    tempfile = Tempfile.new([ "pxrf_priv", ".csv" ])
    tempfile.write(pxrf_csv)
    tempfile.rewind
    uploaded = Rack::Test::UploadedFile.new(tempfile.path, "text/csv", original_filename: "pxrf_priv.csv")

    assert_difference -> { ReferenceAssay.count }, 1 do
      post sample_lab_assays_path(@sample_a),
        params: {
          lab_assay: {
            source_type: "pxrf",
            measured_loi_pct: "7.5",
            promote_to_reference: "1",
            privacy_prompt_shown: "1",
            coordinate_privacy: "fuzzed_2km",
            atlas_privacy_confirmed: "1",
            csv_file: uploaded
          }
        }
    end
    assert_redirected_to sample_path(@sample_a)

    pxrf_assay = @sample_a.reload.latest_assay_result
    pxrf_ref = pxrf_assay.reference_assay
    assert_equal "fuzzed_2km", pxrf_ref.coordinate_privacy
    assert_equal @user_a.id, pxrf_ref.promoted_by_user_id
    assert_equal [ fuzzed_ref.latitude, fuzzed_ref.longitude ], [ pxrf_ref.latitude, pxrf_ref.longitude ]
    assert pxrf_assay.reasoning_log.any? { |entry| entry.include?("(fuzzed ~2 km)") }
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  test "minting and revoking personal API tokens enforces Bearer auth and tenant isolation on /api/v1/materials and exports" do
    # Unauthenticated guest cannot mint API tokens
    post api_tokens_path, params: { api_token: { name: "Blocked Guest Token" } }
    assert_redirected_to new_session_path

    # User A signs in and mints a token on Step 4 of Setup Wizard
    sign_in_as(@user_a, "atlas-password-10")
    assert_difference -> { @user_a.api_tokens.count }, 1 do
      post api_tokens_path, params: { api_token: { name: "Glazecalc MCP Sync" } }
    end
    assert_redirected_to setup_path(step: 4)
    follow_redirect!
    assert_response :success

    token_record = @user_a.api_tokens.last
    plaintext_token = response.body[/dcit_[0-9a-f]{48}/]
    assert plaintext_token.present?, "Expected one-time plaintext dcit_ token on Setup Step 4"
    assert_includes response.body, "Glazecalc MCP Sync"

    # Clear cookies by signing out and test stateless Bearer API requests
    delete session_path

    # Unauthenticated GET /api/v1/materials never leaks User A or User B samples
    get "/api/v1/materials"
    assert_response :success
    unauth_names = JSON.parse(response.body)["materials"].map { |m| m["name"] }
    assert_not_includes unauth_names, "Private Creek Wild Clay"
    assert_not_includes unauth_names, "Cascade Pegmatite Spar"

    get "/api/v1/materials/#{@sample_a.id}"
    assert_response :not_found

    # REQUIRE_API_AUTH=1 requires Bearer token when Authorization header is missing
    prev_env = ENV["REQUIRE_API_AUTH"]
    ENV["REQUIRE_API_AUTH"] = "1"
    begin
      get "/api/v1/materials"
      assert_response :unauthorized
      assert_equal "Bearer API token required", JSON.parse(response.body)["error"]
    ensure
      ENV["REQUIRE_API_AUTH"] = prev_env
    end

    # Valid Bearer token returns ONLY User A's materials and allows User A export
    get "/api/v1/materials", headers: { "Authorization" => "Bearer #{plaintext_token}" }
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body["count"]
    assert_equal [ "Private Creek Wild Clay" ], body["materials"].map { |m| m["name"] }
    assert_not_nil token_record.reload.last_used_at

    get "/api/v1/materials/#{@sample_a.id}", headers: { "Authorization" => "Bearer #{plaintext_token}" }
    assert_response :success
    assert_equal "Private Creek Wild Clay", JSON.parse(response.body)["name"]

    get "/api/v1/materials/#{@sample_b.id}", headers: { "Authorization" => "Bearer #{plaintext_token}" }
    assert_response :not_found

    get sample_glazecalc_export_path(@sample_a, format: :json),
      headers: { "Authorization" => "Bearer #{plaintext_token}" }
    assert_response :success

    get sample_glazecalc_export_path(@sample_b, format: :json),
      headers: { "Authorization" => "Bearer #{plaintext_token}" }
    assert_response :not_found

    # User B cannot revoke User A's token
    sign_in_as(@user_b, "atlas-password-12")
    delete api_token_path(token_record)
    assert_response :not_found
    assert_not token_record.reload.revoked?

    # User A revokes token -> subsequent Bearer calls return 401 Unauthorized
    delete session_path
    sign_in_as(@user_a, "atlas-password-10")
    delete api_token_path(token_record)
    assert_redirected_to setup_path(step: 4)
    assert token_record.reload.revoked?

    delete session_path
    get "/api/v1/materials", headers: { "Authorization" => "Bearer #{plaintext_token}" }
    assert_response :unauthorized
    assert_equal "Invalid or revoked API token", JSON.parse(response.body)["error"]
  end

  test "cross-method privacy sync updates prior pXRF pin to fuzzed_2km, unpublish removes pins, and sample deletion cleans up ReferenceAssays" do
    sign_in_as(@user_b, "atlas-password-12")

    pxrf_csv = "Sample,Si (%),Al (%),Fe (%),Ca (%),K (%),Rb (ppm)\nPEG-PXRF,31.2,8.9,1.1,0.8,4.2,340\n"
    tempfile = Tempfile.new([ "peg_pxrf", ".csv" ])
    tempfile.write(pxrf_csv)
    tempfile.rewind
    uploaded = Rack::Test::UploadedFile.new(tempfile.path, "text/csv", original_filename: "peg_pxrf.csv")

    # 1. Promote handheld pXRF as exact GPS
    assert_difference -> { ReferenceAssay.count }, 1 do
      post sample_lab_assays_path(@sample_b),
        params: {
          lab_assay: {
            source_type: "pxrf",
            measured_loi_pct: "1.2",
            promote_to_reference: "1",
            privacy_prompt_shown: "1",
            coordinate_privacy: "exact",
            atlas_privacy_confirmed: "1",
            csv_file: uploaded
          }
        }
    end
    assert_redirected_to sample_path(@sample_b)

    pxrf_ref = @sample_b.reload.latest_assay_result.reference_assay
    assert_equal "exact", pxrf_ref.coordinate_privacy
    assert_in_delta 47.5580, pxrf_ref.latitude, 0.0001
    assert_in_delta(-117.0780, pxrf_ref.longitude, 0.0001)

    # 2. Promote Lab XRF as fuzzed_2km -> updates the existing pXRF ReferenceAssay to fuzzed_2km too!
    assert_difference -> { ReferenceAssay.count }, 1 do
      post sample_lab_assays_path(@sample_b),
        params: {
          lab_assay: {
            source_type: "verified_lab_xrf",
            lab_name: "Actlabs",
            promote_to_reference: "1",
            privacy_prompt_shown: "1",
            coordinate_privacy: "fuzzed_2km",
            atlas_privacy_confirmed: "1",
            oxides: { "SiO2" => "66.5", "Al2O3" => "18.8", "Fe2O3" => "1.2", "CaO" => "1.0", "K2O" => "11.0", "LOI" => "1.5" }
          }
        }
    end
    assert_redirected_to sample_path(@sample_b)

    xrf_ref = @sample_b.reload.latest_verified_lab_assay.reference_assay
    pxrf_ref.reload
    assert_equal "fuzzed_2km", xrf_ref.coordinate_privacy
    assert_equal "fuzzed_2km", pxrf_ref.coordinate_privacy
    assert_equal "fuzzed_2km", pxrf_ref.raw_metadata["coordinate_privacy"]
    assert_equal [ xrf_ref.latitude, xrf_ref.longitude ], [ pxrf_ref.latitude, pxrf_ref.longitude ]

    # 3. Deleting the UserSample destroys all promoted community_verified_* ReferenceAssays
    ref_ids = [ pxrf_ref.id, xrf_ref.id ]
    assert_difference -> { ReferenceAssay.count }, -2 do
      delete sample_path(@sample_b)
    end
    assert_redirected_to root_path
    assert_empty ReferenceAssay.where(id: ref_ids)

    # 4. Unchecking promote_to_reference on a new assay unpublishes prior community pins on @sample_a
    delete session_path
    sign_in_as(@user_a, "atlas-password-10")
    post sample_lab_assays_path(@sample_a),
      params: {
        lab_assay: {
          source_type: "verified_lab_xrf",
          promote_to_reference: "1",
          privacy_prompt_shown: "1",
          coordinate_privacy: "fuzzed_2km",
          atlas_privacy_confirmed: "1",
          oxides: { "SiO2" => "61.0", "Al2O3" => "19.0", "Fe2O3" => "5.0", "CaO" => "2.0", "K2O" => "3.0", "LOI" => "10.0" }
        }
      }
    prior_ref_id = @sample_a.reload.latest_verified_lab_assay.reference_assay_id
    assert_not_nil prior_ref_id

    assert_difference -> { ReferenceAssay.count }, -1 do
      post sample_lab_assays_path(@sample_a),
        params: {
          lab_assay: {
            source_type: "verified_lab_icpms",
            promote_to_reference: "0",
            oxides: { "SiO2" => "61.5", "Al2O3" => "18.5", "Fe2O3" => "5.0", "CaO" => "2.0", "K2O" => "3.0", "LOI" => "10.0" }
          }
        }
    end
    assert_nil ReferenceAssay.find_by(id: prior_ref_id)
    assert_not @sample_a.assay_results.reload.any?(&:promoted_to_reference?)
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  test "posting scalar String csv_file path to LabAssaysController#create is ignored cleanly and 422 re-render preserves form fields" do
    sign_in_as(@user_a, "atlas-password-10")

    assert_no_difference [ "AssayResult.count", "ReferenceAssay.count" ] do
      post sample_lab_assays_path(@sample_a),
        params: {
          lab_assay: {
            source_type: "verified_lab_xrf",
            lab_name: "WSU Retained Name",
            lab_report_ref: "WSU-KEEP-42",
            csv_file: "/etc/hosts"
          }
        },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Provide a lab report CSV file or enter oxide weight percentages."
    assert_includes response.body, "WSU Retained Name"
    assert_includes response.body, "WSU-KEEP-42"

    assert_no_difference -> { AssayResult.count } do
      post sample_lab_assays_path(@sample_a),
        params: {
          lab_assay: {
            source_type: "pxrf",
            csv_file: "/etc/hosts"
          }
        },
        headers: { "Accept" => "text/vnd.turbo-stream.html" }
    end

    assert_response :unprocessable_entity
    assert_includes response.body, "Provide a handheld pXRF CSV or TSV file"
  end

  private

  def sign_in_as(user, password)
    post session_path, params: { session: { email: user.email, password: password } }
    assert_redirected_to root_path
  end

  def haversine_km(lat1, lng1, lat2, lng2)
    rad = Math::PI / 180.0
    dlat = (lat2 - lat1) * rad
    dlng = (lng2 - lng1) * rad
    a = Math.sin(dlat / 2.0)**2 +
        Math.cos(lat1 * rad) * Math.cos(lat2 * rad) * Math.sin(dlng / 2.0)**2
    2.0 * EARTH_RADIUS_KM * Math.atan2(Math.sqrt(a), Math.sqrt(1.0 - a))
  end
end
