# frozen_string_literal: true

class PrintSheetsController < ApplicationController
  BATCH_GRAM_SCALES = [ 100, 500, 1000, 5000 ].freeze

  layout "print"

  def sample
    @sample = sample_scope
      .includes(:geologic_unit, :soil_profile, :assay_results, :field_observations)
      .find(params[:id])
    @assay_result = @sample.latest_assay_result
    @field_observation = @sample.latest_field_observation
    @hazard_report = Chemistry::HazardScreenerService.call(
      assay_result: @assay_result,
      user_sample: @sample
    )
    @tile_stamp = format("DCIT-S%04d", @sample.id)
    @qr_svg = Media::QrSvgGenerator.call(sample_url(@sample))
    @back_path = sample_path(@sample)
  end

  def blend
    @sample_ids = parse_sample_ids(extract_param(:sample_ids))
    @stock_keys = parse_stock_keys(extract_param(:stock_keys))
    @target_cone = normalized_cone_param
    @surface = normalized_surface_param
    @recipe_title = extract_param(:recipe_title).to_s.strip.presence
    @back_path = blends_path(request.query_parameters)

    selected = resolve_selected_materials(@sample_ids, @stock_keys)
    @blend_result = Chemistry::BlendRecipeBuilder.call(
      samples: selected,
      target_cone: @target_cone,
      surface: @surface
    )

    @recipe_heading = @recipe_title || @blend_result.default_recipe_title
    @batch_scales = BATCH_GRAM_SCALES
    @scaled_batch_rows = build_scaled_batch_rows(@blend_result.optimal)
    @test_cup_candidates = @blend_result.line_blend? ? @blend_result.candidates : @blend_result.top_candidates(12)
    @tile_stamp = build_blend_tile_stamp(@sample_ids, @blend_result)
    @qr_svg = Media::QrSvgGenerator.call(blends_url(request.query_parameters))
  rescue ArgumentError => e
    @error_message = e.message
    render :blend, status: :unprocessable_content
  end

  private

  def sample_scope
    respond_to?(:scoped_samples, true) ? scoped_samples : UserSample.all
  end

  def resolve_selected_materials(sample_ids, stock_keys)
    resolve_selected_samples(sample_ids) + resolve_selected_stock_materials(stock_keys)
  end

  def resolve_selected_samples(ids)
    return [] if ids.empty?

    by_id = sample_scope
      .includes(:geologic_unit, :field_observations, :assay_results)
      .where(id: ids)
      .index_by(&:id)

    ids.filter_map { |id| by_id[id] }
  end

  def resolve_selected_stock_materials(keys)
    return [] if keys.empty?

    keys.filter_map { |key| Chemistry::StockMaterialsCatalog.find(key) }
  end

  def build_scaled_batch_rows(candidate)
    candidate.weights.map do |entry|
      pct = entry[:percentage].to_f
      grams = BATCH_GRAM_SCALES.index_with do |scale_grams|
        ((pct / 100.0) * scale_grams).round(1)
      end

      {
        sample: entry[:sample],
        percentage: entry[:percentage],
        grams: grams
      }
    end
  end

  def build_blend_tile_stamp(sample_ids, blend_result)
    lead_code = sample_ids.any? ? format("S%04d", sample_ids.first) : "STK"
    mode_code = blend_result.line_blend? ? "LB" : "TX"
    "DCIT-#{mode_code}-#{lead_code}-C#{blend_result.target_cone}"
  end

  def parse_sample_ids(raw)
    Array(raw)
      .flatten
      .reject(&:blank?)
      .map(&:to_i)
      .select(&:positive?)
      .uniq
  end

  def parse_stock_keys(raw)
    Array(raw)
      .flatten
      .map { |val| val.to_s.strip.downcase.delete_prefix("stock:") }
      .reject(&:blank?)
      .select { |key| Chemistry::StockMaterialsCatalog.find(key).present? }
      .uniq
  end

  def normalized_cone_param
    raw = extract_param(:target_cone).to_s.strip
    return raw if %w[6 10].include?(raw)

    current_studio_setting.blend_target_cone
  end

  def normalized_surface_param
    raw = extract_param(:surface).to_s.strip.downcase
    return raw if %w[gloss matte].include?(raw)

    current_studio_setting.default_blend_surface
  end

  def extract_param(key)
    params[key].presence || params.dig(:blend, key).presence
  end
end
