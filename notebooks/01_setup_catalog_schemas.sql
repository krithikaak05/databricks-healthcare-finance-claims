-- 01_setup_catalog_schemas.sql
-- Unity Catalog + compute setup.
-- Mirrors the "three Snowflake warehouses / three schemas" workload-isolation
-- story, expressed in Databricks primitives.

-- ============================================================
-- Catalog + schemas (medallion layers, split Gold by persona)
-- ============================================================
CREATE CATALOG IF NOT EXISTS healthcare_claims;

CREATE SCHEMA IF NOT EXISTS healthcare_claims.bronze
  COMMENT 'Raw landing zone. Schema-on-read. Never mutated in place.';

CREATE SCHEMA IF NOT EXISTS healthcare_claims.silver
  COMMENT 'Cleaned, typed, deduplicated. SCD2 members, SCD1 providers.';

CREATE SCHEMA IF NOT EXISTS healthcare_claims.gold_claims_ops
  COMMENT 'Curated marts for Claims Operations persona (PHI-masked).';

CREATE SCHEMA IF NOT EXISTS healthcare_claims.gold_finance
  COMMENT 'Curated marts for Finance/Actuarial persona (reserving, reinsurance, loss ratio). Separate from claims_ops on purpose -- different sensitivity dimension, different audience.';

-- Dev sandbox catalog (populated later via SHALLOW CLONE, see 10_time_travel_cloning.sql)
CREATE CATALOG IF NOT EXISTS healthcare_claims_dev;
CREATE SCHEMA IF NOT EXISTS healthcare_claims_dev.silver;

-- ============================================================
-- Unity Catalog Volume for Bronze ingestion.
-- Why a Volume instead of an external S3/ADLS/GCS bucket path?
-- Free Edition (and many restricted workspaces) does not permit wiring
-- Auto Loader to a custom external storage location. A Unity Catalog
-- Volume is Databricks-managed storage that works everywhere, including
-- Free Edition -- upload synthetic data here directly through the Catalog
-- UI and Auto Loader reads from it exactly like it would an external bucket.
-- ============================================================
CREATE VOLUME IF NOT EXISTS healthcare_claims.bronze.landing_zone
  COMMENT 'Upload synthetic parquet files here (from data_generator.py) for Auto Loader to pick up.';

-- ============================================================
-- Compute: workload isolation (aspirational on Free Edition)
-- Why three warehouses/policies instead of one shared cluster?
-- Loading, transforming, and BI querying have different
-- concurrency/size needs and different cost owners. One
-- oversized shared cluster is the #1 cause of runaway lakehouse
-- bills -- naming that unprompted is a senior-level signal.
--
-- NOTE: Free Edition caps you to ONE SQL Warehouse at 2X-Small -- you
-- cannot actually provision the three below there. Skip this block
-- entirely on Free Edition and use the single built-in serverless
-- warehouse for everything; explain the workload-isolation design as
-- what you'd apply once real volume justified it, without over-
-- provisioning for a portfolio-scale workload. Run this block on a
-- paid workspace or a free trial instead.
-- ============================================================
-- CREATE WAREHOUSE IF NOT EXISTS load_wh
--   WAREHOUSE_SIZE = 'Small' AUTO_STOP_MINS = 10 ENABLE_SERVERLESS_COMPUTE = TRUE;
-- CREATE WAREHOUSE IF NOT EXISTS transform_wh
--   WAREHOUSE_SIZE = 'Medium' AUTO_STOP_MINS = 10 ENABLE_SERVERLESS_COMPUTE = TRUE;
-- CREATE WAREHOUSE IF NOT EXISTS analytics_wh
--   WAREHOUSE_SIZE = 'X-Small' AUTO_STOP_MINS = 5 ENABLE_SERVERLESS_COMPUTE = TRUE ENABLE_PHOTON = TRUE;

-- ============================================================
-- Roles / groups (created in the account console or via SCIM in
-- practice -- listed here for reference; grants happen in
-- 06_unity_catalog_governance.sql). Not creatable on a single-user
-- Free Edition account (no admin console access) -- cite these as the
-- design intent even where they can't be provisioned here.
-- ============================================================
-- claims_analyst    -- Claims Ops persona, no PHI, no finance schema access
-- phi_viewer        -- can see unmasked diagnosis codes
-- claims_admin      -- full claims_ops schema access
-- finance_analyst   -- Finance/Actuarial persona, no raw diagnosis codes
-- finance_admin     -- full gold_finance schema access, all regions

-- ============================================================
-- Grant the Databricks App's service principal access (needed once you
-- deploy the Streamlit dashboard as a Databricks App -- its identity is
-- separate from your own user account and needs explicit grants).
-- Replace the ID below with your own app's DATABRICKS_CLIENT_ID, visible
-- in the app's environment or its Settings page.
-- ============================================================
-- GRANT USE CATALOG ON CATALOG healthcare_claims TO `<app-client-id>`;
-- GRANT USE SCHEMA, SELECT ON SCHEMA healthcare_claims.gold_claims_ops TO `<app-client-id>`;
-- GRANT USE SCHEMA, SELECT ON SCHEMA healthcare_claims.gold_finance TO `<app-client-id>`;
-- GRANT USE SCHEMA, SELECT ON SCHEMA healthcare_claims.silver TO `<app-client-id>`;
