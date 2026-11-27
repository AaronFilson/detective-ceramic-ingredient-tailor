# frozen_string_literal: true

require "test_helper"

module Inference
  class SampleEstimatorServiceTest < ActiveSupport::TestCase
    BaselineStubResult = Struct.new(
      :oxides,
      :oxide_ranges,
      :confidence_score,
      :reasoning_log,
      keyword_init: true
    )

    setup do
      @sample = UserSample.create!(
        title: "Tacoma Glacial Drift Clay",
        material_category: :wild_clay,
        latitude: 47.2529,
        longitude: -122.4443
      )

      @baseline_oxides = {
        "SiO2"  => 60.0,
        "Al2O3" => 18.0,
        "Fe2O3" => 4.5,
        "CaO"   => 2.2,
        "MgO"   => 1.9,
        "Na2O"  => 1.8,
        "K2O"   => 2.6,
        "TiO2"  => 0.8,
        "P2O5"  => 0.1,
        "MnO"   => 0.1,
        "LOI"   => 8.0
      }

      @baseline_ranges = @baseline_oxides.transform_values do |med|
        {
          "min"    => [ med - 2.0, 0.0 ].max.round(2),
          "q1"     => [ med - 1.0, 0.0 ].max.round(2),
          "median" => med,
          "q3"     => (med + 1.2).round(2),
          "max"    => (med + 2.5).round(2),
          "iqr"    => 2.2
        }
      end

      @stub_estimator = ->(_sample) do
        BaselineStubResult.new(
          oxides: @baseline_oxides,
          oxide_ranges: @baseline_ranges,
          confidence_score: 0.72,
          reasoning_log: [ "Spatial baseline from 18 PNW reference assays within 50 km of Tacoma, WA." ]
        )
      end
    end

    test "persists baseline AssayResult with UMF when no field observation exists" do
      assay = SampleEstimatorService.call(@sample, baseline_estimator: @stub_estimator)

      assert assay.persisted?
      assert assay.spatial_heuristic_estimate?
      assert_equal @sample.id, assay.user_sample_id
      assert_equal 100.0, assay.oxides.values.sum.round(2)
      assert_equal 2.2, assay.oxides["CaO"]
      assert_equal BigDecimal("0.72"), assay.confidence_score
      assert_equal 1, assay.reasoning_log.length
      assert_in_delta 1.0, assay.umf_formula["flux_total"], 0.0001
      assert_operator assay.umf_formula["si_al_ratio"], :>, 4.0
    end

    test "automatically applies latest_field_observation, combines reasoning_log, and updates existing heuristic AssayResult" do
      initial = SampleEstimatorService.call(@sample, baseline_estimator: @stub_estimator)
      lab_xrf = @sample.assay_results.create!(
        source_type: :verified_lab_xrf,
        oxides: @baseline_oxides,
        confidence_score: 0.99,
        reasoning_log: [ "Verified lab XRF upload" ]
      )

      @sample.field_observations.create!(
        vinegar_fizz: :vigorous,
        fired_color: "buff white",
        plasticity: :high_plastic
      )

      updated = SampleEstimatorService.call(@sample, baseline_estimator: @stub_estimator)

      # Reuses existing spatial_heuristic_estimate record instead of duplicating
      assert_equal initial.id, updated.id
      assert_equal 1, @sample.assay_results.spatial_heuristic_estimate.count

      # Leaves verified lab XRF record untouched
      assert_equal BigDecimal("0.99"), lab_xrf.reload.confidence_score
      assert_equal [ "Verified lab XRF upload" ], lab_xrf.reasoning_log

      # Applies field observation modifiers cleanly
      assert_equal 100.0, updated.oxides.values.sum.round(2)
      assert_operator updated.oxides["CaO"], :>, 4.5
      assert_operator updated.oxides["LOI"], :>, 10.0
      assert_operator updated.oxides["Fe2O3"], :<, 1.5
      assert_operator updated.confidence_score, :>, BigDecimal("0.72")
      assert_operator updated.confidence_score, :<=, BigDecimal("1.0")

      assert_equal 4, updated.reasoning_log.length
      assert_includes updated.reasoning_log.first, "Spatial baseline"
      assert updated.reasoning_log.any? { |line| line.include?("CaCO3") }
      assert updated.reasoning_log.any? { |line| line.include?("Fe2O3") }
      assert updated.reasoning_log.any? { |line| line.match?(/kaolinite\/illite/i) }
    end

    test "explicit field_observation argument takes precedence over latest_field_observation" do
      @sample.field_observations.create!(vinegar_fizz: :vigorous)
      explicit_obs = @sample.field_observations.build(fired_cone: "10", melt_state: :refractory_chalky)

      assay = SampleEstimatorService.call(
        @sample,
        field_observation: explicit_obs,
        baseline_estimator: @stub_estimator
      )

      assert_operator assay.oxides["Al2O3"], :>, @baseline_oxides["Al2O3"] + 3.0
      assert_operator assay.oxides["CaO"], :<, @baseline_oxides["CaO"]
      assert assay.reasoning_log.any? { |line| line.include?("Cone 10") }
      assert_not assay.reasoning_log.any? { |line| line.include?("CaCO3") }
    end

    test "clamps combined confidence_score into 0.0..1.0" do
      high_conf_estimator = ->(_sample) do
        BaselineStubResult.new(
          oxides: @baseline_oxides,
          oxide_ranges: @baseline_ranges,
          confidence_score: 0.96,
          reasoning_log: [ "High confidence local cluster" ]
        )
      end

      obs = @sample.field_observations.create!(
        vinegar_fizz: :vigorous,
        fired_color: "terracotta",
        fired_cone: "06",
        melt_state: :melted_fluid
      )

      assay = SampleEstimatorService.call(
        @sample,
        field_observation: obs,
        baseline_estimator: high_conf_estimator
      )

      assert_equal BigDecimal("1.0"), assay.confidence_score
    end

    test "falls back to category defaults when baseline_estimator is omitted and spatial baseline service is absent" do
      obs = @sample.field_observations.create!(vinegar_fizz: :slight)
      assay = SampleEstimatorService.call(@sample, field_observation: obs)

      assert assay.persisted?
      assert_equal 100.0, assay.oxides.values.sum.round(2)
      assert_in_delta 1.0, assay.umf_formula["flux_total"], 0.0001
      assert_operator assay.confidence_score, :>, BigDecimal("0.0")
      assert_operator assay.confidence_score, :<=, BigDecimal("1.0")
    end

    test "raises ArgumentError when user_sample is nil" do
      assert_raises(ArgumentError) do
        SampleEstimatorService.call(nil)
      end
    end

    test "persists minor_oxides and trace_elements_ppm and computes full-oxide UMF with and without field observations" do
      rich_stub = Struct.new(
        :oxides,
        :oxide_ranges,
        :minor_oxides,
        :trace_elements_ppm,
        :confidence_score,
        :reasoning_log,
        keyword_init: true
      )

      minor_estimator = ->(_sample) do
        rich_stub.new(
          oxides: @baseline_oxides,
          oxide_ranges: @baseline_ranges,
          minor_oxides: { "Li2O" => 1.5, "SrO" => 0.4, "B2O3" => 0.8 },
          trace_elements_ppm: { "As" => 65.0, "Rb" => 410.0 },
          confidence_score: 0.74,
          reasoning_log: [ "Spatial baseline with propagated minor/trace chemistry." ]
        )
      end

      # Without field observation
      assay = SampleEstimatorService.call(@sample, baseline_estimator: minor_estimator)
      assert_equal({ "Li2O" => 1.5, "SrO" => 0.4, "B2O3" => 0.8 }, assay.minor_oxides)
      assert_equal({ "As" => 65.0, "Rb" => 410.0 }, assay.trace_elements_ppm)
      assert_includes assay.umf_formula["fluxes"].keys, "Li2O"
      assert_includes assay.umf_formula["fluxes"].keys, "SrO"
      assert_includes assay.umf_formula["intermediates"].keys, "B2O3"
      assert_in_delta 1.0, assay.umf_formula["flux_total"], 0.0005

      # With field observation — minor oxides remain persisted and included in recalculated UMF
      obs = @sample.field_observations.create!(vinegar_fizz: :slight, fired_color: "buff")
      modified_assay = SampleEstimatorService.call(@sample, field_observation: obs, baseline_estimator: minor_estimator)

      assert_equal assay.id, modified_assay.id
      assert_equal({ "Li2O" => 1.5, "SrO" => 0.4, "B2O3" => 0.8 }, modified_assay.minor_oxides)
      assert_equal({ "As" => 65.0, "Rb" => 410.0 }, modified_assay.trace_elements_ppm)
      assert_includes modified_assay.umf_formula["fluxes"].keys, "Li2O"
      assert_includes modified_assay.umf_formula["intermediates"].keys, "B2O3"
      assert_equal(
        Chemistry::UmfCalculator.call(modified_assay.oxides, minor_oxides: modified_assay.minor_oxides),
        modified_assay.umf_formula
      )
    end

    test "keeps zero-minor-oxide UMF byte-for-byte identical when baseline carries no minor oxides" do
      assay = SampleEstimatorService.call(@sample, baseline_estimator: @stub_estimator)

      assert_equal({}, assay.minor_oxides)
      assert_equal({}, assay.trace_elements_ppm)
      assert_equal Chemistry::UmfCalculator.call(assay.oxides), assay.umf_formula
    end
  end
end
