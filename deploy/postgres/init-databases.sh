#!/usr/bin/env bash
# Bootstrap script executed once when `dci-tailor-db` (postgis/postgis:16-3.4) initializes an empty volume.
# Runs as the `postgres` superuser ($POSTGRES_USER) and provisions isolated non-superuser roles + databases
# (`dci_tailor` -> `dci_tailor_production`, `dci_tailor_staging` -> `dci_tailor_staging`) with PostGIS enabled.
set -euo pipefail

: "${APP_DB_PASSWORD:?APP_DB_PASSWORD must be set}"
: "${STAGING_DB_PASSWORD:?STAGING_DB_PASSWORD must be set}"

psql -v ON_ERROR_STOP=1 \
  --username "${POSTGRES_USER:-postgres}" \
  --dbname "${POSTGRES_DB:-postgres}" \
  -v app_pw="$APP_DB_PASSWORD" \
  -v staging_pw="$STAGING_DB_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE dci_tailor WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD %L', :'app_pw')
WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'dci_tailor')\gexec

ALTER ROLE dci_tailor WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'app_pw';

SELECT format('CREATE ROLE dci_tailor_staging WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD %L', :'staging_pw')
WHERE NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'dci_tailor_staging')\gexec

ALTER ROLE dci_tailor_staging WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD :'staging_pw';

SELECT 'CREATE DATABASE dci_tailor_production OWNER dci_tailor ENCODING ''UTF8'''
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'dci_tailor_production')\gexec

REVOKE CONNECT ON DATABASE dci_tailor_production FROM PUBLIC;
GRANT CONNECT ON DATABASE dci_tailor_production TO dci_tailor;

SELECT 'CREATE DATABASE dci_tailor_staging OWNER dci_tailor_staging ENCODING ''UTF8'''
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'dci_tailor_staging')\gexec

REVOKE CONNECT ON DATABASE dci_tailor_staging FROM PUBLIC;
GRANT CONNECT ON DATABASE dci_tailor_staging TO dci_tailor_staging;

\connect dci_tailor_production
CREATE EXTENSION IF NOT EXISTS postgis;
GRANT ALL ON SCHEMA public TO dci_tailor;

\connect dci_tailor_staging
CREATE EXTENSION IF NOT EXISTS postgis;
GRANT ALL ON SCHEMA public TO dci_tailor_staging;
SQL
