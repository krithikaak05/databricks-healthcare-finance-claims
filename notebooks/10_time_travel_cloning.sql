-- 10_time_travel_cloning.sql
-- Delta Lake Time Travel + Shallow/Deep Clone -- direct replacement for
-- Snowflake Time Travel (AT/BEFORE) + zero-copy cloning.
--
-- NOTE ON OBJECT TYPES: Silver tables (claims_staging, members_scd2, etc.)
-- are Lakeflow STREAMING TABLEs -- physical Delta tables under the hood.
-- Gold tables (claims_fact, reserves_fact, etc.) are MATERIALIZED VIEWs --
-- also physically backed by Delta storage, but the catalog's DDL commands
-- (ALTER TABLE, DESCRIBE DETAIL) enforce a stricter "must be a plain table"
-- check on these, as already seen with CLUSTER BY and DESCRIBE DETAIL
-- earlier in this project. DESCRIBE HISTORY and time-travel SELECT queries
-- may or may not hit the same restriction -- test on a Silver streaming
-- table first (most likely to work cleanly), then try Gold if curious.

-- ============================================================
-- Inspect table history / versions -- try on a Silver streaming table first
-- ============================================================
DESCRIBE HISTORY healthcare_claims.silver.claims_staging;

-- ============================================================
-- Query a prior version -- e.g. to compare a metric before/after a
-- suspected bad Silver load. Adjust the version number based on what
-- DESCRIBE HISTORY actually shows above (versions start at 0).
-- ============================================================
SELECT COUNT(*) FROM healthcare_claims.silver.claims_staging VERSION AS OF 0;

-- ============================================================
-- Zero-copy dev sandbox -- e.g. for an actuary testing a new reserving
-- methodology without touching production data.
-- Why shallow clone instead of a full copy?
-- No extra storage cost until the dev copy's data actually diverges from
-- the source -- identical pitch to Snowflake's zero-copy clone.
-- ============================================================
CREATE CATALOG IF NOT EXISTS healthcare_claims_dev;
CREATE SCHEMA IF NOT EXISTS healthcare_claims_dev.silver;

CREATE TABLE healthcare_claims_dev.silver.claims_staging_clone
  SHALLOW CLONE healthcare_claims.silver.claims_staging;

-- Use DEEP CLONE instead when you need a fully independent physical copy
-- (e.g. handing data to an external auditor who must not share underlying
-- files with production storage).
-- CREATE TABLE healthcare_claims_dev.silver.claims_staging_audit_copy
--   DEEP CLONE healthcare_claims.silver.claims_staging;

-- ============================================================
-- Recover from a bad load without restoring from an external backup
-- Why this matters for a platform/consulting role specifically: the
-- client question "how do we roll back a bad transform without a backup
-- restore" has the exact same one-line answer as it did on Snowflake --
-- RESTORE reads the Delta transaction log, no external backup system
-- required. CAUTION: only run this if you actually want to roll back --
-- it mutates the live table. Safe to skip for a portfolio demo once
-- DESCRIBE HISTORY / VERSION AS OF above have already proven the concept.
-- ============================================================
-- RESTORE TABLE healthcare_claims.silver.claims_staging TO VERSION AS OF 0;

-- ============================================================
-- Clean up old versions once you're confident you won't need to travel
-- back further than your compliance/retention window requires (Time
-- Travel history is bounded by VACUUM retention, default 7 days -- extend
-- deliberately for regulated data, not indefinitely by default)
-- ============================================================
-- VACUUM healthcare_claims.silver.claims_staging RETAIN 168 HOURS; -- 7 days
