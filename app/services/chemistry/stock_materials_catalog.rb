# frozen_string_literal: true

module Chemistry
  # Authentic catalog of 18 commercial ceramic studio staple modifiers (fluxes,
  # frits, stabilizers, glass formers, and iron colorant) for blending alongside
  # assayed local wild clays, wood ashes, and crushed rocks.
  class StockMaterialsCatalog
    ROLE_LABELS = {
      "flux" => "Fluxes & Frits",
      "stabilizer" => "Stabilizers, Glass Formers & Colorants"
    }.freeze

    TAG_STYLES = {
      boron: "bg-violet-100 text-violet-900 border-violet-300",
      lithium: "bg-teal-100 text-teal-900 border-teal-300",
      ro_flux: "bg-amber-100 text-amber-950 border-amber-300",
      alkali: "bg-emerald-100 text-emerald-900 border-emerald-300",
      alumina: "bg-[#B84A27]/12 text-[#963B1D] border-[#B84A27]/25",
      silica: "bg-[#1E4E79]/12 text-[#1E4E79] border-[#1E4E79]/25",
      iron: "bg-red-100 text-red-900 border-red-300"
    }.freeze

    StockMaterial = Struct.new(
      :key,
      :title,
      :role,
      :material_category,
      :oxides,
      :minor_oxides,
      :notes,
      keyword_init: true
    ) do
      def id
        "stock:#{key}"
      end

      def stock?
        true
      end

      def persisted?
        false
      end

      def flux?
        role == "flux"
      end

      def quick_tags
        tags = []
        tags << { label: "B₂O₃", tone: :boron } if minor_oxides["B2O3"].to_f >= 5.0
        tags << { label: "Li₂O", tone: :lithium } if minor_oxides["Li2O"].to_f >= 2.0
        tags << { label: "SrO", tone: :ro_flux } if minor_oxides["SrO"].to_f >= 10.0
        tags << { label: "ZnO", tone: :ro_flux } if minor_oxides["ZnO"].to_f >= 10.0
        tags << { label: "CaO", tone: :ro_flux } if oxides["CaO"].to_f >= 10.0
        tags << { label: "MgO", tone: :ro_flux } if oxides["MgO"].to_f >= 10.0
        tags << { label: "Na₂O", tone: :alkali } if oxides["Na2O"].to_f >= 5.0
        tags << { label: "K₂O", tone: :alkali } if oxides["K2O"].to_f >= 5.0
        tags << { label: "Al₂O₃", tone: :alumina } if oxides["Al2O3"].to_f >= 25.0
        tags << { label: "SiO₂", tone: :silica } if oxides["SiO2"].to_f >= 90.0
        tags << { label: "Fe₂O₃", tone: :iron } if oxides["Fe2O3"].to_f >= 20.0
        tags
      end

      def summary_oxides(limit = 4)
        combined = {}
        oxides.each do |oxide, value|
          next if oxide == "LOI" || value.to_f <= 0.0

          combined[oxide] = value.to_f
        end
        minor_oxides.each do |oxide, value|
          combined[oxide] = value.to_f if value.to_f.positive?
        end

        combined
          .sort_by { |oxide, value| [ minor_oxides.key?(oxide) ? 0 : 1, -value ] }
          .first(limit)
      end
    end

    RAW_MATERIALS = [
      # Fluxes (RO / R2O / Boron / Lithium)
      {
        key: "whiting",
        title: "Whiting (CaCO3)",
        role: "flux",
        material_category: "other",
        oxides: {
          "SiO2" => 0.30, "Al2O3" => 0.10, "Fe2O3" => 0.05,
          "CaO" => 55.45, "MgO" => 0.30, "LOI" => 43.80
        },
        minor_oxides: {},
        notes: "High-purity calcium carbonate (CaCO3). Primary Cone 6-10 RO flux for durability, glaze hardness, and matte crystal growth."
      },
      {
        key: "wollastonite",
        title: "Wollastonite",
        role: "flux",
        material_category: "crushed_rock",
        oxides: {
          "SiO2" => 50.90, "Al2O3" => 0.25, "Fe2O3" => 0.55,
          "CaO" => 46.80, "MgO" => 0.20, "MnO" => 0.10, "LOI" => 1.20
        },
        minor_oxides: {},
        notes: "Natural calcium silicate (CaSiO3). Low-LOI alternative to whiting that supplies CaO and SiO2 while reducing pinholing."
      },
      {
        key: "dolomite",
        title: "Dolomite",
        role: "flux",
        material_category: "crushed_rock",
        oxides: {
          "SiO2" => 0.80, "Al2O3" => 0.20, "Fe2O3" => 0.10,
          "CaO" => 30.20, "MgO" => 21.50, "LOI" => 47.20
        },
        minor_oxides: {},
        notes: "Calcium-magnesium carbonate (CaMg(CO3)2). Produces silky MgO satin mattes and helps lower thermal expansion."
      },
      {
        key: "talc",
        title: "Talc",
        role: "flux",
        material_category: "crushed_rock",
        oxides: {
          "SiO2" => 61.50, "Al2O3" => 0.70, "Fe2O3" => 0.50,
          "CaO" => 0.80, "MgO" => 31.00, "LOI" => 5.50
        },
        minor_oxides: {},
        notes: "Hydrated magnesium silicate. Low-expansion MgO flux for stoneware glazes and smooth satin-matte surfaces."
      },
      {
        key: "ferro_frit_3134",
        title: "Ferro Frit 3134",
        role: "flux",
        material_category: "other",
        oxides: {
          "SiO2" => 46.50, "CaO" => 20.10, "Na2O" => 10.30, "LOI" => 0.00
        },
        minor_oxides: { "B2O3" => 23.10 },
        notes: "Alumina-free high-boron calcium-sodium frit (B2O3 23.1%). Premier Cone 6 melter; pairs cleanly with wild clays and whiting."
      },
      {
        key: "ferro_frit_3124",
        title: "Ferro Frit 3124",
        role: "flux",
        material_category: "other",
        oxides: {
          "SiO2" => 55.30, "Al2O3" => 9.90, "CaO" => 14.07,
          "Na2O" => 6.28, "K2O" => 0.68, "LOI" => 0.00
        },
        minor_oxides: { "B2O3" => 13.77 },
        notes: "Balanced Cone 6 calcium-boron frit containing alumina (B2O3 13.8%). Versatile clear glaze base with moderate expansion."
      },
      {
        key: "ferro_frit_3195",
        title: "Ferro Frit 3195",
        role: "flux",
        material_category: "other",
        oxides: {
          "SiO2" => 48.35, "Al2O3" => 11.98, "CaO" => 11.35,
          "Na2O" => 5.72, "LOI" => 0.00
        },
        minor_oxides: { "B2O3" => 22.60 },
        notes: "High-boron Cone 6 CaO/B2O3 frit (B2O3 22.6%) with built-in alumina and lower sodium than Frit 3134 for improved glaze fit."
      },
      {
        key: "gerstley_borate",
        title: "Gerstley Borate",
        role: "flux",
        material_category: "other",
        oxides: {
          "SiO2" => 13.70, "Al2O3" => 1.40, "Fe2O3" => 0.30,
          "CaO" => 20.10, "MgO" => 3.50, "Na2O" => 5.00,
          "K2O" => 0.40, "LOI" => 27.60
        },
        minor_oxides: { "B2O3" => 28.00 },
        notes: "Natural calcium-sodium borate (B2O3 28.0%). Powerful Cone 6 melter and slurry suspender promoting rich phase separation."
      },
      {
        key: "custer_feldspar",
        title: "Custer Potash Feldspar",
        role: "flux",
        material_category: "crushed_rock",
        oxides: {
          "SiO2" => 68.50, "Al2O3" => 17.00, "Fe2O3" => 0.10,
          "CaO" => 0.30, "MgO" => 0.10, "Na2O" => 3.00,
          "K2O" => 10.50, "LOI" => 0.50
        },
        minor_oxides: {},
        notes: "High-potash feldspar (K2O 10.5%). Classic R2O flux for Cone 6-10 stoneware and celadon glazes."
      },
      {
        key: "minspar_200",
        title: "Minspar 200 Soda Feldspar",
        role: "flux",
        material_category: "crushed_rock",
        oxides: {
          "SiO2" => 68.20, "Al2O3" => 19.00, "Fe2O3" => 0.08,
          "CaO" => 1.62, "MgO" => 0.10, "Na2O" => 6.80,
          "K2O" => 3.90, "LOI" => 0.30
        },
        minor_oxides: {},
        notes: "High-sodium feldspar (Na2O 6.8%, K2O 3.9%). Active Cone 6-10 melt promoter; watch COE at high percentages."
      },
      {
        key: "nepheline_syenite",
        title: "Nepheline Syenite",
        role: "flux",
        material_category: "crushed_rock",
        oxides: {
          "SiO2" => 60.70, "Al2O3" => 23.30, "Fe2O3" => 0.10,
          "CaO" => 0.70, "MgO" => 0.10, "Na2O" => 9.80,
          "K2O" => 4.60, "LOI" => 0.70
        },
        minor_oxides: {},
        notes: "Silica-undersaturated high-alkali feldspathoid (Na2O 9.8%, K2O 4.6%). Strong flux ideal for shino and fluid mid-fire melts."
      },
      {
        key: "spodumene",
        title: "Spodumene",
        role: "flux",
        material_category: "crushed_rock",
        oxides: {
          "SiO2" => 64.50, "Al2O3" => 26.20, "Fe2O3" => 0.20,
          "CaO" => 0.10, "MgO" => 0.10, "Na2O" => 0.30,
          "K2O" => 0.40, "LOI" => 0.90
        },
        minor_oxides: { "Li2O" => 7.30 },
        notes: "Natural lithium aluminosilicate (Li2O 7.3%). Potent low-expansion R2O flux that reduces crazing while brightening glaze melts."
      },
      {
        key: "strontium_carbonate",
        title: "Strontium Carbonate",
        role: "flux",
        material_category: "other",
        oxides: {
          "CaO" => 0.40, "LOI" => 29.80
        },
        minor_oxides: { "SrO" => 69.80 },
        notes: "Non-toxic barium alternative (SrO 69.8%). Produces silky satin-matte surfaces and widens Cone 6 firing range."
      },
      {
        key: "zinc_oxide",
        title: "Zinc Oxide",
        role: "flux",
        material_category: "other",
        oxides: {
          "LOI" => 0.20
        },
        minor_oxides: { "ZnO" => 99.80 },
        notes: "Auxiliary RO flux and low-expansion matte/crystalline helper (ZnO 99.8%). Best used in small additions (1-6%)."
      },

      # Stabilizers / Glass Formers / Colorants
      {
        key: "epk_kaolin",
        title: "EPK Kaolin",
        role: "stabilizer",
        material_category: "wild_clay",
        oxides: {
          "SiO2" => 45.73, "Al2O3" => 37.36, "Fe2O3" => 0.79,
          "TiO2" => 0.37, "CaO" => 0.18, "MgO" => 0.09,
          "Na2O" => 0.06, "K2O" => 0.33, "P2O5" => 0.24, "LOI" => 14.85
        },
        minor_oxides: {},
        notes: "Edgar Plastic Kaolin (Al2O3 37.4%). Adds glaze alumina to stabilize melt viscosity, suspend slurries, and build matte textures."
      },
      {
        key: "om4_ball_clay",
        title: "OM4 Ball Clay",
        role: "stabilizer",
        material_category: "wild_clay",
        oxides: {
          "SiO2" => 53.60, "Al2O3" => 30.80, "Fe2O3" => 1.00,
          "TiO2" => 1.60, "CaO" => 0.20, "MgO" => 0.30,
          "Na2O" => 0.20, "K2O" => 0.90, "LOI" => 11.40
        },
        minor_oxides: {},
        notes: "Old Mine #4 Ball Clay (Al2O3 30.8%, SiO2 53.6%). Fine-particle plastic clay improving raw glaze adhesion and alumina stability."
      },
      {
        key: "silica",
        title: "Silica / Flint (325 mesh)",
        role: "stabilizer",
        material_category: "crushed_rock",
        oxides: {
          "SiO2" => 99.50, "Al2O3" => 0.20, "Fe2O3" => 0.05, "LOI" => 0.25
        },
        minor_oxides: {},
        notes: "Pure 325-mesh quartz glass former (SiO2 99.5%). Raises Si:Al ratio for gloss, increases durability, and lowers thermal expansion."
      },
      {
        key: "red_iron_oxide",
        title: "Red Iron Oxide",
        role: "stabilizer",
        material_category: "other",
        oxides: {
          "SiO2" => 2.00, "Al2O3" => 0.50, "Fe2O3" => 95.50,
          "CaO" => 0.50, "LOI" => 1.50
        },
        minor_oxides: {},
        notes: "Concentrated ferric oxide colorant (Fe2O3 95.5%). Yields celadon (1-2%), amber/tea-dust (4-6%), and tenmoku (8-10%)."
      }
    ].freeze

    def self.build_material(spec)
      full_oxides = CeramicOxides::KEYS.each_with_object({}) do |oxide, acc|
        acc[oxide] = spec.fetch(:oxides).fetch(oxide, 0.0).to_f
      end.freeze

      minors = spec.fetch(:minor_oxides).transform_keys(&:to_s).transform_values(&:to_f).freeze

      StockMaterial.new(
        key: spec.fetch(:key),
        title: spec.fetch(:title),
        role: spec.fetch(:role),
        material_category: spec.fetch(:material_category),
        oxides: full_oxides,
        minor_oxides: minors,
        notes: spec.fetch(:notes)
      ).freeze
    end
    private_class_method :build_material

    MATERIALS = RAW_MATERIALS.map { |spec| build_material(spec) }.freeze
    BY_KEY = MATERIALS.index_by(&:key).freeze
    KEYS = MATERIALS.map(&:key).freeze

    def self.all
      MATERIALS
    end

    def self.find(key)
      return nil if key.nil?

      normalized = key.to_s.strip.downcase.delete_prefix("stock:")
      BY_KEY[normalized]
    end

    def self.grouped_by_role
      ROLE_LABELS.keys.each_with_object({}) do |role, acc|
        acc[role] = MATERIALS.select { |material| material.role == role }
      end
    end

    def self.keys
      KEYS
    end

    def self.role_label(role)
      ROLE_LABELS.fetch(role.to_s, role.to_s.titleize)
    end

    def self.tag_classes(tone)
      TAG_STYLES.fetch(tone.to_sym, "bg-stone-100 text-stone-700 border-stone-300")
    end
  end
end
