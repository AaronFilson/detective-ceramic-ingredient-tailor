# Ceramic Material Assay & Inference Platform

A Ruby on Rails 8 + PostgreSQL/PostGIS web application that helps studio potters estimate the chemical oxide composition and Unity Molecular Formula (UMF) of locally dug wild clays, crushed rocks, and wood ash, and export material definitions directly into **Glazecalc** and **Glaze Vault**.

## Stack
- **Backend:** Ruby 3.3, Rails 8.1, PostgreSQL 16 + PostGIS (`activerecord-postgis-adapter`, `rgeo`, `rgeo-geojson`), Solid Queue
- **Frontend:** Hotwire (Turbo + Stimulus), Tailwind CSS v4, Leaflet 1.9.4 + Macrostrat Carto geologic map tiles
- **Testing:** Minitest + WebMock

## Quick Start (Docker Compose)

```bash
# 1. Start PostGIS and prepare/migrate/seed the database (50 PNW/North American reference assays)
docker compose up -d db
docker compose run --rm web bundle exec rails db:prepare db:migrate db:seed

# 2. Launch the studio workbench at http://localhost:3000
docker compose up web

# 3. Run the full Minitest suite
docker compose run --rm web bundle exec rails test
```

## Geochemical Data Ingestion

Import USGS NGDB or EarthChem geochemical datasets idempotently (handles direct oxide wt%, `FeO`/`FeOT` conversion, and elemental ppm/wt% stoichiometric conversion; normalizes to 100.0% including LOI; skips rows missing `SiO2`/`Al2O3` or coordinates):

```bash
docker compose run --rm web bundle exec rake "geochem:import_usgs[db/seeds/sample_assays.csv]"
docker compose run --rm web bundle exec rake "geochem:import_earthchem[path/to/earthchem.csv]"
```

## Architecture Overview
- **Schema & Models (`app/models/`):** `GeologicUnit` (PostGIS SRID 4326 `geometry` boundary + Macrostrat cache), `ReferenceAssay` (geographic `st_point` + JSONB normalized oxides), `UserSample`, `FieldObservation`, `AssayResult`, shared `CeramicOxides` and `Geolocatable` concerns.
- **Macrostrat & Spatial Baseline (`app/services/clients/`, `app/services/inference/`):**
  - `Clients::MacrostratClient`: PostGIS `ST_Covers` cache-first lookup against Macrostrat v2 (`format=geojson`) with retry/timeout handling.
  - `Inference::BaselineEstimatorService`: 5-tier PostGIS `ST_DWithin` baseline estimator (15 km -> 50 km -> unfiltered 50 km -> global lithology -> category defaults) computing `min`, `q1`, `median`, `q3`, `max`, and `iqr`.
- **Heuristic Field Rules & UMF (`app/services/inference/`, `app/services/chemistry/`):**
  - `Inference::ObservationModifierService`: Adjusts oxide ranges and logs transparent reasoning for vinegar fizz (`CaO` + stoichiometric `LOI`), raw/fired color (`Fe2O3`), melt state & Orton cone, plasticity, and slaking behavior.
  - `Chemistry::UmfCalculator`: Computes ceramic Unity Molecular Formula (`RO + R2O = 1.0`), `SiO2:Al2O3` ratio, equivalent weight, and fired formula weight.
  - `Inference::SampleEstimatorService`: Orchestrates baseline + field observation modifiers + UMF and persists `AssayResult`.
- **Studio Workbench (`app/controllers/samples_controller.rb`, `app/controllers/field_observations_controller.rb`, `app/javascript/controllers/`):** Split-screen Leaflet + Macrostrat overlay (`map_picker_controller.js`), Turbo Frame geologic unit lookup, Turbo Stream live field observation updates, and clipboard export (`clipboard_controller.js`).
- **Glazecalc & Glaze Vault Exports (`app/services/exporters/`, `app/controllers/sample_exports_controller.rb`, `app/controllers/api/v1/materials_controller.rb`):**
  - `GET /samples/:id/export/glazecalc.json` (`?download=1` for attachment)
  - `GET /samples/:id/export/glaze_vault.json` (`?download=1` for attachment, native `glaze-vault-export` v1 format + full provenance)
  - `GET /api/v1/materials` & `GET /api/v1/materials/:id` (JSON API for MCP/webhook consumers)
