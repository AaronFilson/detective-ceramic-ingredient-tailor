# frozen_string_literal: true

class BlendsController < ApplicationController
  def index
    @available_samples = load_available_samples
    @stock_groups = Chemistry::StockMaterialsCatalog.grouped_by_role
    @target_cone = normalized_cone_param
    @surface = normalized_surface_param
    @recipe_title = extract_param(:recipe_title).to_s.strip.presence
    @selected_sample_ids = parse_sample_ids(extract_param(:sample_ids))
    @selected_stock_keys = parse_stock_keys(extract_param(:stock_keys))
    @auto_reformulated = false

    if @selected_sample_ids.empty? && @selected_stock_keys.empty?
      if @available_samples.size >= 2
        @selected_sample_ids = default_sample_ids(@available_samples)
      elsif @available_samples.size == 1
        @selected_sample_ids = [ @available_samples.first.id ]
        @selected_stock_keys = default_stock_keys_for_cone(@target_cone)
        @auto_reformulated = true
      end
    end

    selected = resolve_selected_materials(@selected_sample_ids, @selected_stock_keys)
    if selected.size.between?(2, 3)
      @blend_result = Chemistry::BlendRecipeBuilder.call(
        samples: selected,
        target_cone: @target_cone,
        surface: @surface
      )
    end
  rescue ArgumentError => e
    @error_message = e.message
  end

  def create
    @available_samples = load_available_samples
    @stock_groups = Chemistry::StockMaterialsCatalog.grouped_by_role
    @target_cone = normalized_cone_param
    @surface = normalized_surface_param
    @recipe_title = extract_param(:recipe_title).to_s.strip.presence
    @selected_sample_ids = parse_sample_ids(extract_param(:sample_ids))
    @selected_stock_keys = parse_stock_keys(extract_param(:stock_keys))
    @auto_reformulated = false

    selected = resolve_selected_materials(@selected_sample_ids, @selected_stock_keys)
    @blend_result = Chemistry::BlendRecipeBuilder.call(
      samples: selected,
      target_cone: @target_cone,
      surface: @surface
    )

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "blend_results",
          partial: "blends/results",
          locals: results_locals
        )
      end
      format.html { render :index }
    end
  rescue ArgumentError => e
    @error_message = e.message
    @blend_result = nil

    respond_to do |format|
      format.turbo_stream do
        render turbo_stream: turbo_stream.replace(
          "blend_results",
          partial: "blends/results",
          locals: results_locals
        ), status: :unprocessable_content
      end
      format.html { render :index, status: :unprocessable_content }
    end
  end

  def export_glazecalc
    blend_result, recipe_title = build_export_blend
    payload = Chemistry::BlendRecipeBuilder.to_glazecalc_export(
      blend_result,
      recipe_title: recipe_title
    )
    slug = export_slug(recipe_title || blend_result.default_recipe_title)

    response.headers["Content-Disposition"] = %(attachment; filename="#{slug}-glazecalc-bundle.json")
    render json: JSON.pretty_generate(payload)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  def export_glaze_vault
    blend_result, recipe_title = build_export_blend
    payload = Chemistry::BlendRecipeBuilder.to_glaze_vault_export(
      blend_result,
      recipe_title: recipe_title
    )
    slug = export_slug(recipe_title || blend_result.default_recipe_title)

    response.headers["Content-Disposition"] = %(attachment; filename="#{slug}-glaze-vault-bundle.json")
    render json: JSON.pretty_generate(payload)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_content
  end

  private

  def load_available_samples
    UserSample
      .includes(:geologic_unit, :field_observations, :assay_results)
      .joins(:assay_results)
      .distinct
      .order(updated_at: :desc, id: :desc)
      .select { |sample| sample.latest_assay_result&.oxides.present? }
  end

  def resolve_selected_materials(sample_ids, stock_keys)
    resolve_selected_samples(sample_ids) + resolve_selected_stock_materials(stock_keys)
  end

  def resolve_selected_samples(ids)
    return [] if ids.empty?

    by_id = UserSample
      .includes(:geologic_unit, :field_observations, :assay_results)
      .where(id: ids)
      .index_by(&:id)

    ids.filter_map { |id| by_id[id] }
  end

  def resolve_selected_stock_materials(keys)
    return [] if keys.empty?

    keys.filter_map { |key| Chemistry::StockMaterialsCatalog.find(key) }
  end

  def default_sample_ids(samples)
    distinct_categories = samples.uniq(&:material_category)
    picks = distinct_categories.size >= 2 ? distinct_categories.first(2) : samples.first(2)
    picks.map(&:id)
  end

  def default_stock_keys_for_cone(cone)
    cone == "10" ? %w[whiting epk_kaolin] : %w[whiting ferro_frit_3134]
  end

  def build_export_blend
    ids = parse_sample_ids(extract_param(:sample_ids))
    stock_keys = parse_stock_keys(extract_param(:stock_keys))
    selected = resolve_selected_materials(ids, stock_keys)
    cone = extract_param(:target_cone).presence || current_studio_setting.blend_target_cone
    surface = extract_param(:surface).presence || current_studio_setting.default_blend_surface
    recipe_title = extract_param(:recipe_title).to_s.strip.presence

    blend_result = Chemistry::BlendRecipeBuilder.call(
      samples: selected,
      target_cone: cone,
      surface: surface
    )

    [ blend_result, recipe_title ]
  end

  def results_locals
    {
      blend_result: @blend_result,
      error_message: @error_message,
      recipe_title: @recipe_title,
      available_samples: @available_samples,
      auto_reformulated: @auto_reformulated
    }
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

  def export_slug(title)
    title.to_s.parameterize.presence || "local-glaze-blend"
  end
end
