# frozen_string_literal: true

module Exporters
  # Serializes an AssayResult (or UserSample via its latest AssayResult) into a
  # Glaze Vault v1 archival export payload ("glaze-vault-export") complete with
  # material entry, studio firing sheet, and full geologic/diagnostic provenance.
  class GlazeVaultSerializer
    FORMAT_NAME = "glaze-vault-export"
    EXPORT_VERSION = 1
    APP_VERSION = "detective-ceramic-ingredient-tailor-1.0"

    MATERIAL_CLASSES = [
      "ball clay",
      "kaolin",
      "fire clay",
      "stoneware clay",
      "earthenware clay",
      "plasticizer",
      "feldspar",
      "nepheline syenite",
      "silica",
      "talc",
      "wollastonite",
      "grog",
      "refractory",
      "deflocculant",
      "flocculant",
      "other"
    ].freeze

    RED_EARTHENWARE_PATTERN = /\b(red|terracotta|rust|mahogany|ochre|brick|chocolate|dark\s+brown|iron)\b/i
    LOW_FIRE_CONES = %w[022 021 020 019 018 017 016 015 014 013 012 011 010 09 08 07 06 05 04 03 02 01 1 2 3 4 5 6].freeze

    def self.call(assay_result_or_sample)
      new(assay_result_or_sample).call
    end

    def initialize(assay_result_or_sample)
      @sample, @assay_result = GlazecalcMaterialSerializer.resolve_records(assay_result_or_sample)
    end

    def call
      normalized = GlazecalcMaterialSerializer.normalize_oxides(@assay_result.oxides)
      observations = ordered_observations
      latest_obs = observations.last
      now_iso = Time.current.utc.iso8601

      material = {
        "name" => @sample.title.to_s,
        "category" => "material",
        "oxides" => build_oxide_entries(normalized),
        "loi" => format("%.2f", normalized.fetch("LOI")),
        "class" => classify_material_class(normalized, latest_obs),
        "notes" => build_notes(latest_obs),
        "revision" => 1,
        "savedAt" => (@assay_result.updated_at || @assay_result.created_at || Time.current).utc.iso8601
      }

      sheet = build_sheet(observations)
      material["sheet"] = sheet if sheet.any?

      {
        "format" => FORMAT_NAME,
        "version" => EXPORT_VERSION,
        "exportedAt" => now_iso,
        "appVersion" => APP_VERSION,
        "recipes" => [],
        "materials" => [ material ],
        "provenance" => build_provenance(normalized, observations)
      }
    end

    private

    def build_oxide_entries(normalized)
      GlazecalcMaterialSerializer::FIRED_OXIDES.filter_map do |oxide|
        pct = normalized[oxide]
        next unless pct.positive?

        {
          "oxide" => oxide,
          "percent" => format("%.2f", pct)
        }
      end
    end

    def build_sheet(observations)
      sheet = {}

      cone_obs = observations.reverse.find { |obs| obs.fired_cone.present? }
      sheet["cone"] = cone_obs.fired_cone.to_s.strip if cone_obs

      shrinkage_obs = observations.reverse.find { |obs| obs.shrinkage_percent.present? }
      if shrinkage_obs
        sheet["totalShrinkage"] = format_number_string(shrinkage_obs.shrinkage_percent)
      end

      sheet
    end

    def classify_material_class(normalized, latest_obs)
      context = classification_context_text(latest_obs)
      sio2 = normalized.fetch("SiO2", 0.0)
      al2o3 = normalized.fetch("Al2O3", 0.0)
      fe2o3 = normalized.fetch("Fe2O3", 0.0)
      cao = normalized.fetch("CaO", 0.0)
      mgo = normalized.fetch("MgO", 0.0)
      alkalis = normalized.fetch("Na2O", 0.0) + normalized.fetch("K2O", 0.0)
      loi = normalized.fetch("LOI", 0.0)

      material_class = case @sample.material_category.to_s
      when "wood_ash"
        "other"
      when "crushed_rock"
        classify_crushed_rock(context, sio2:, al2o3:, cao:, mgo:, alkalis:, loi:)
      when "wild_clay"
        classify_wild_clay(context, al2o3:, fe2o3:, cao:, mgo:, alkalis:, latest_obs:)
      else
        classify_other_material(context)
      end

      MATERIAL_CLASSES.include?(material_class) ? material_class : "other"
    end

    def classify_crushed_rock(context, sio2:, al2o3:, cao:, mgo:, alkalis:, loi:)
      return "nepheline syenite" if context.match?(/\b(nepheline|syenite)\b/i)
      return "silica" if context.match?(/\b(quartz|quartzite|chert|flint|silica|sandstone)\b/i) || (sio2 >= 90.0 && al2o3 <= 5.0)
      return "talc" if context.match?(/\b(talc|steatite|soapstone)\b/i) || (mgo >= 20.0 && sio2 >= 45.0)
      return "wollastonite" if context.match?(/\bwollastonite\b/i) || (cao >= 30.0 && sio2 >= 35.0 && al2o3 <= 5.0)
      if context.match?(/\b(feldspar|granite|pegmatite|rhyolite|aplite|monzonite|granodiorite|diorite)\b/i) ||
          (alkalis >= 6.0 && al2o3 >= 12.0 && loi <= 3.0)
        return "feldspar"
      end

      "other"
    end

    def classify_wild_clay(context, al2o3:, fe2o3:, cao:, mgo:, alkalis:, latest_obs:)
      return "kaolin" if context.match?(/\b(kaolin|kaolinite|china\s+clay)\b/i)
      return "ball clay" if context.match?(/\bball\s+clay\b/i)
      return "fire clay" if context.match?(/\bfire\s*clay\b/i)
      return "earthenware clay" if context.match?(/\b(earthenware|terracotta)\b/i)
      return "stoneware clay" if context.match?(/\bstoneware\b/i)

      return "kaolin" if al2o3 >= 30.0 && fe2o3 <= 1.5 && (alkalis + cao + mgo) <= 2.5
      return "ball clay" if al2o3 >= 24.0 && fe2o3 <= 2.0 && latest_obs&.high_plastic?
      return "fire clay" if al2o3 >= 22.0 && latest_obs&.refractory_chalky?

      fired_red = latest_obs&.fired_color.to_s.match?(RED_EARTHENWARE_PATTERN)
      low_fire_melt = (latest_obs&.melted_fluid? || latest_obs&.bloated?) &&
        LOW_FIRE_CONES.include?(latest_obs&.fired_cone.to_s.strip)

      if fe2o3 >= 4.5 || cao >= 6.0 || fired_red || low_fire_melt
        return "earthenware clay"
      end

      "stoneware clay"
    end

    def classify_other_material(context)
      return "plasticizer" if context.match?(/\b(bentonite|veegum|hectorite|plasticizer)\b/i)
      return "grog" if context.match?(/\b(grog|chamotte)\b/i)
      return "refractory" if context.match?(/\b(mullite|kyanite|alumina|refractory)\b/i)
      return "kaolin" if context.match?(/\bkaolin\b/i)
      return "feldspar" if context.match?(/\bfeldspar\b/i)
      return "nepheline syenite" if context.match?(/\b(nepheline|syenite)\b/i)
      return "silica" if context.match?(/\b(silica|quartz|flint)\b/i)
      return "talc" if context.match?(/\btalc\b/i)
      return "wollastonite" if context.match?(/\bwollastonite\b/i)

      "other"
    end

    def classification_context_text(latest_obs)
      parts = [
        @sample.title,
        @sample.notes,
        @sample.geologic_unit&.name,
        @sample.geologic_unit&.strat_name,
        *@sample.geologic_unit&.lithology_terms,
        latest_obs&.raw_color,
        latest_obs&.fired_color
      ]
      parts.compact.map(&:to_s).join(" ")
    end

    def build_notes(latest_obs)
      sections = []
      sections << @sample.notes.strip if @sample.notes.present?

      if (unit = @sample.geologic_unit)
        unit_bits = [ unit.name, unit.strat_name ].compact.map(&:strip).reject(&:empty?).uniq.join(" / ")
        label = unit_bits.empty? ? "Macrostrat ##{unit.macrostrat_id}" : "#{unit_bits} (Macrostrat ##{unit.macrostrat_id})"
        label = "#{label}, #{unit.age}" if unit.age.present?
        terms = unit.lithology_terms
        label = "#{label} [#{terms.join(', ')}]" if terms.any?
        sections << "Geologic Unit: #{label}"
      end

      if @sample.latitude.present? && @sample.longitude.present?
        sections << format("GPS: %.5f, %.5f", @sample.latitude.to_f, @sample.longitude.to_f)
      end

      if (obs_summary = GlazecalcMaterialSerializer.field_observation_summary(latest_obs))
        sections << obs_summary
      end

      reasoning = Array(@assay_result.reasoning_log)
        .map { |entry| GlazecalcMaterialSerializer.format_reasoning_entry(entry) }
        .reject(&:empty?)

      if reasoning.any?
        sections << "Assay Reasoning: #{reasoning.join(' | ')}"
      end

      sections.join("\n")
    end

    def build_provenance(normalized, observations)
      umf = @assay_result.umf_formula.present? ? @assay_result.umf_formula : GlazecalcMaterialSerializer.compute_umf(normalized)

      {
        "sample" => {
          "id" => @sample.id,
          "title" => @sample.title,
          "material_category" => @sample.material_category,
          "latitude" => @sample.latitude&.to_f,
          "longitude" => @sample.longitude&.to_f,
          "notes" => @sample.notes,
          "created_at" => @sample.created_at&.utc&.iso8601
        },
        "geologic_unit" => serialize_geologic_unit(@sample.geologic_unit),
        "field_observations" => observations.map { |obs| serialize_observation(obs) },
        "assay_result" => {
          "id" => @assay_result.id,
          "source_type" => @assay_result.source_type,
          "confidence_score" => @assay_result.confidence_score&.to_f,
          "oxides" => normalized,
          "oxide_ranges" => @assay_result.oxide_ranges || {},
          "umf_formula" => umf,
          "reasoning_log" => Array(@assay_result.reasoning_log)
        }
      }
    end

    def serialize_geologic_unit(unit)
      return nil if unit.nil?

      {
        "macrostrat_id" => unit.macrostrat_id,
        "name" => unit.name,
        "strat_name" => unit.strat_name,
        "lithology" => unit.lithology,
        "lithology_terms" => unit.lithology_terms,
        "age" => unit.age
      }
    end

    def serialize_observation(obs)
      {
        "id" => obs.id,
        "vinegar_fizz" => obs.vinegar_fizz,
        "slaking_behavior" => obs.slaking_behavior,
        "plasticity" => obs.plasticity,
        "raw_color" => obs.raw_color,
        "fired_cone" => obs.fired_cone,
        "fired_color" => obs.fired_color,
        "melt_state" => obs.melt_state,
        "shrinkage_percent" => obs.shrinkage_percent&.to_f,
        "created_at" => obs.created_at&.utc&.iso8601
      }
    end

    def ordered_observations
      if @sample.field_observations.loaded?
        @sample.field_observations.sort_by { |obs| [ obs.created_at || Time.at(0), obs.id || 0 ] }
      else
        @sample.field_observations.order(created_at: :asc, id: :asc).to_a
      end
    end

    def format_number_string(value)
      format("%.2f", value.to_f).sub(/\.?0+\z/, "")
    end
  end
end
