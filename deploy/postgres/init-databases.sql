-- Bootstrap script executed once when `dci-tailor-db` (postgis/postgis:16-3.4) initializes an empty volume.
-- The container entrypoint creates the `dci_tailor` role and `dci_tailor_production` database first.
-- Here we create the isolated `dci_tailor_staging` role + database and pre-install PostGIS in both so
-- staging runs without superuser privileges and cannot read or modify `dci_tailor_production`.
-- After `kamal accessory boot db`, set the staging password from SSM `/dci-tailor/staging/postgres-password`
-- (see deploy/README.md, Step 5).

CREATE EXTENSION IF NOT EXISTS postgis;

DO
$$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = 'dci_tailor_staging') THEN
    CREATE ROLE dci_tailor_staging WITH LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE;
  END IF;
END
$$;

REVOKE CONNECT ON DATABASE dci_tailor_production FROM PUBLIC;
GRANT CONNECT ON DATABASE dci_tailor_production TO dci_tailor;

SELECT 'CREATE DATABASE dci_tailor_staging OWNER dci_tailor_staging ENCODING ''UTF8'''
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'dci_tailor_staging')\gexec

REVOKE CONNECT ON DATABASE dci_tailor_staging FROM PUBLIC;
GRANT CONNECT ON DATABASE dci_tailor_staging TO dci_tailor_staging;

\connect dci_tailor_staging

CREATE EXTENSION IF NOT EXISTS postgis;
GRANT ALL ON SCHEMA public TO dci_tailor_staging;
