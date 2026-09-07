-- 03_silver_transformations.sql
-- Lakeflow Declarative Pipeline definitions (formerly Delta Live Tables).
-- Run this file as part of a Lakeflow pipeline. This is the direct
-- replacement for the Snowflake Streams + Tasks CDC layer.
--
-- Why Lakeflow Declarative Pipelines here instead of hand-written
-- Structured Streaming + MERGE jobs? APPLY CHANGES INTO gives you CDC
-- upsert/delete handling and native SCD Type 1 / Type 2 support in one
-- declarative statement, with the engine managing checkpointing, ordering,
-- and out-of-order event handling for you. That's strictly less code than
-- the Snowflake Stream + Task + hand-written MERGE it replaces.
--
-- NOTE ON COLUMN REFERENCES: Bronze was ingested from parquet files, so
-- Auto Loader preserved the original flat column names (claim_id,
-- member_id, etc.) directly -- there's no nested "raw_data" struct column
-- to unpack. If your Bronze source were JSON landed as a single VARIANT/
-- MAP-style payload column instead, you'd reference fields as
-- raw_data.claim_id -- adjust accordingly if you change ingestion formats.

-- ============================================================
-- Claims: streaming table (source is append-only Bronze)
-- ============================================================
CREATE OR REFRESH STREAMING TABLE healthcare_claims.silver.claims_staging
COMMENT 'Typed, cleaned claims -- one row per claim, latest known state.'
AS SELECT
  claim_id::STRING            AS claim_id,
  member_id::STRING           AS member_id,
  provider_id::STRING         AS provider_id,
  claim_date::DATE            AS claim_date,
  claim_amount::DECIMAL(12,2) AS claim_amount,
  claim_status::STRING        AS claim_status,
  diagnosis_code::STRING      AS diagnosis_code,
  _loaded_at
FROM STREAM(healthcare_claims.bronze.claims_raw);

-- Why APPEND_ONLY-style handling here (no APPLY CHANGES needed)?
-- Claims Bronze landing is insert-only -- we never update Bronze rows in
-- place -- so a simple typed streaming table (no upsert semantics) is
-- sufficient and cheaper than tracking deletes/updates we will never see.
-- This mirrors the Snowflake `APPEND_ONLY = TRUE` stream decision exactly.

-- ============================================================
-- Claim status updates: genuine CDC -- status transitions over time
-- ============================================================
CREATE OR REFRESH STREAMING TABLE healthcare_claims.silver.claim_status_current;

APPLY CHANGES INTO healthcare_claims.silver.claim_status_current
FROM (
  SELECT
    claim_id,
    status,
    CAST(status_timestamp AS TIMESTAMP) AS status_timestamp
  FROM STREAM(healthcare_claims.bronze.claim_status_updates_raw)
)
KEYS (claim_id)
SEQUENCE BY status_timestamp
STORED AS SCD TYPE 1;

-- Why the CAST here?
-- Bronze landed status_timestamp as TIMESTAMP_NTZ (timestamp without
-- timezone) because that's how the local pandas/pyarrow parquet writer
-- typed it. Delta requires a manual table-feature enablement step before
-- a table can use TIMESTAMP_NTZ. Casting to the plain TIMESTAMP type here
-- avoids that extra step entirely and is a completely safe conversion for
-- this column since we don't need timezone-aware semantics for it.

-- Why SCD Type 1 (overwrite) for status, but Type 2 for members below?
-- We only ever care about a claim's CURRENT status for operational
-- dashboards -- history of every status flicker lives in Bronze already if
-- ever needed for audit. Members need point-in-time history because claims
-- must be judged against the plan a member had on the date of service.

-- ============================================================
-- Members: SCD Type 2 -- Lakeflow native, replaces the hand-written
-- Snowflake MERGE against a Stream
-- ============================================================
CREATE OR REFRESH STREAMING TABLE healthcare_claims.silver.members_scd2;

APPLY CHANGES INTO healthcare_claims.silver.members_scd2
FROM STREAM(healthcare_claims.bronze.members_raw)
KEYS (member_id)
SEQUENCE BY effective_date
STORED AS SCD TYPE 2;

-- Why SCD Type 2 for members, not Type 1?
-- Overwriting (Type 1) would silently corrupt historical claims analysis --
-- a claim from 2023 must be evaluated against the 2023 plan, not today's
-- plan. This is a real data-modeling judgment call, not a memorized
-- definition, and it's identical reasoning to the Snowflake version.

-- ============================================================
-- Providers: SCD Type 1 -- no history needed, network status just changes
-- ============================================================
CREATE OR REFRESH STREAMING TABLE healthcare_claims.silver.providers_current;

APPLY CHANGES INTO healthcare_claims.silver.providers_current
FROM STREAM(healthcare_claims.bronze.providers_raw)
KEYS (provider_id)
SEQUENCE BY _loaded_at
STORED AS SCD TYPE 1;

-- ============================================================
-- Reinsurance treaties: small slowly-changing dimension (finance module)
-- ============================================================
CREATE OR REFRESH STREAMING TABLE healthcare_claims.silver.reinsurance_treaties;

APPLY CHANGES INTO healthcare_claims.silver.reinsurance_treaties
FROM STREAM(healthcare_claims.bronze.reinsurance_treaties_raw)
KEYS (treaty_id)
SEQUENCE BY effective_date
STORED AS SCD TYPE 2;

-- Why SCD Type 2 for treaties too?
-- Treaty terms (attachment point, cession %) get renegotiated at renewal.
-- A cession calculated for a 2023 claim must use the 2023 treaty terms, not
-- this year's renegotiated terms -- same point-in-time correctness argument
-- as members, applied to the finance side of the platform.

-- ============================================================
-- Claim notes: pass-through typed table (target for ai_query in step 08)
-- ============================================================
CREATE OR REFRESH STREAMING TABLE healthcare_claims.silver.claim_notes
COMMENT 'Unstructured adjuster/denial notes, typed and deduped for ai_query() enrichment.'
AS SELECT DISTINCT
  claim_id::STRING   AS claim_id,
  note_text::STRING  AS note_text,
  note_date::DATE    AS note_date
FROM STREAM(healthcare_claims.bronze.claim_notes_raw);

-- ============================================================
-- Premium transactions (finance module) -- pass-through typed table
-- ============================================================
CREATE OR REFRESH STREAMING TABLE healthcare_claims.silver.premium_ledger
AS SELECT
  member_id::STRING             AS member_id,
  period_date::DATE             AS period_date,
  premium_amount::DECIMAL(10,2) AS premium_amount,
  payment_status::STRING        AS payment_status
FROM STREAM(healthcare_claims.bronze.premium_transactions_raw);

-- ============================================================
-- Reserves (finance module) -- pass-through typed table, Gold layer
-- aggregates this by valuation date (see 07_finance_reserving.sql)
-- ============================================================
CREATE OR REFRESH STREAMING TABLE healthcare_claims.silver.reserves_typed
AS SELECT
  claim_id::STRING             AS claim_id,
  valuation_date::DATE         AS valuation_date,
  case_reserve::DECIMAL(12,2)  AS case_reserve,
  ibnr_reserve::DECIMAL(12,2)  AS ibnr_reserve
FROM STREAM(healthcare_claims.bronze.reserves_raw);
