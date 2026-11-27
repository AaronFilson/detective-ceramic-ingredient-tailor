# frozen_string_literal: true

require "test_helper"

class GlazecalcPushesControllerTest < ActionDispatch::IntegrationTest
  setup do
    WebMock.reset!

    @sample = UserSample.create!(
      title: "Olympic Peninsula Slip Clay",
      material_category: :wild_clay,
      latitude: 48.1181,
      longitude: -123.4307
    )

    @sample.assay_results.create!(
      source_type: :spatial_heuristic_estimate,
      confidence_score: 0.79,
      oxides: {
        "SiO2" => 59.0,
        "Al2O3" => 17.5,
        "Fe2O3" => 6.2,
        "CaO" => 3.5,
        "MgO" => 2.1,
        "Na2O" => 1.3,
        "K2O" => 2.0,
        "LOI" => 8.4
      }
    )
  end

  test "POST /samples/:sample_id/glazecalc_push as TURBO_STREAM replaces #glazecalc_push_result on 201 success" do
    stub = stub_request(:post, "https://glazecalc.com/api/materials")
      .with(headers: { "Authorization" => "Bearer transient_secret_token_42" })
      .to_return(
        status: 201,
        headers: { "Content-Type" => "application/json" },
        body: { id: "gc_9001", name: "Olympic Peninsula Slip Clay" }.to_json
      )

    post sample_glazecalc_push_path(@sample),
      params: {
        base_url: "https://glazecalc.com",
        api_token: "transient_secret_token_42"
      },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_requested stub, times: 1
    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, '<turbo-stream action="replace" target="glazecalc_push_result">'
    assert_includes response.body, 'id="glazecalc_push_result"'
    assert_includes response.body, "Pushed to Glazecalc"
    assert_includes response.body, "Olympic Peninsula Slip Clay"
    assert_includes response.body, "gc_9001"
    assert_not_includes response.body, "transient_secret_token_42"
  end

  test "POST /samples/:sample_id/glazecalc_push as TURBO_STREAM returns 422 with scope reminder on 401" do
    stub_request(:post, "https://glazecalc.com/api/materials")
      .to_return(
        status: 401,
        headers: { "Content-Type" => "application/json" },
        body: { error: "Token lacks write scope" }.to_json
      )

    post sample_glazecalc_push_path(@sample),
      params: {
        base_url: "https://glazecalc.com",
        api_token: "bad_token_123"
      },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_response :unprocessable_content
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, '<turbo-stream action="replace" target="glazecalc_push_result">'
    assert_includes response.body, "Glazecalc Push Failed"
    assert_includes response.body, "Read and change"
    assert_not_includes response.body, "bad_token_123"
  end

  test "POST /samples/:sample_id/glazecalc_push rejects missing token without calling remote API" do
    stub = stub_request(:post, %r{glazecalc\.com})

    post sample_glazecalc_push_path(@sample),
      params: { base_url: "https://glazecalc.com", api_token: "" },
      headers: { "Accept" => "text/vnd.turbo-stream.html" }

    assert_not_requested stub
    assert_response :unprocessable_content
    assert_includes response.body, "Glazecalc API token is required"
  end

  test "POST /samples/:sample_id/glazecalc_push as HTML redirects back to sample with flash message" do
    stub_request(:post, "https://glazecalc.com/api/materials")
      .to_return(
        status: 201,
        headers: { "Content-Type" => "application/json" },
        body: { id: "gc_html_1", name: "Olympic Peninsula Slip Clay" }.to_json
      )

    post sample_glazecalc_push_path(@sample),
      params: {
        base_url: "https://glazecalc.com",
        api_token: "html_secret_token"
      }

    assert_redirected_to sample_path(@sample)
    assert_includes flash[:notice], "gc_html_1"
    assert_not_includes flash[:notice], "html_secret_token"
  end

  test "form partial renders collapsible details card with password-masked token and transient note" do
    html = ApplicationController.render(
      partial: "glazecalc_pushes/form",
      locals: { sample: @sample }
    )

    assert_includes html, 'id="glazecalc_push_panel"'
    assert_includes html, "<details"
    assert_includes html, "Push Directly to Glazecalc Account"
    assert_includes html, 'type="password"'
    assert_includes html, 'autocomplete="off"'
    assert_includes html, "https://glazecalc.com"
    assert_includes html, "Token is used transiently for this request and never stored"
    assert_includes html, 'id="glazecalc_push_result"'
  end
end
