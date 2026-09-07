-- 05_liquid_clustering_perf.sql
-- Liquid Clustering verification -- the centerpiece performance decision.
--
<<<<<<< HEAD
-- NOTE: claims_fact is a Lakeflow-managed materialized
=======
--  claims_fact is a Lakeflow-managed materialized
>>>>>>> 977ed8e85d6cfafc68b1ba778ebdb214d645642f
-- view, not a plain Delta table. ALTER TABLE ... CLUSTER BY and
-- DESCRIBE DETAIL both fail on it with EXPECT_TABLE_NOT_VIEW errors.
-- Liquid Clustering is instead declared directly inside the view's CREATE
-- statement via CLUSTER BY -- see 04_gold_claims_ops.sql. This file is
-- for VERIFICATION only.

-- ============================================================
-- Verify clustering took effect. DESCRIBE DETAIL fails on a materialized
-- view; DESCRIBE EXTENDED works and shows a "Clustering Information"
-- section plus a table_properties entry:
--   clusteringColumns=[["claim_date"],["provider_id"]]
-- ============================================================
DESCRIBE EXTENDED healthcare_claims.gold_claims_ops.claims_fact;

-- Why (claim_date, provider_id) and not member_id?
-- Dashboards filter by date range constantly, and providers are the
-- deliberately skewed dimension (80% of claims from 20% of providers)
-- that network/audit teams query directly. member_id is too
-- high-cardinality and isn't a common range-filter column here --
-- clustering on it would burn OPTIMIZE compute for no pruning benefit.
-- The answer isn't "cluster by the primary key," it's "cluster by what
-- WHERE clauses actually filter on."

-- ============================================================
-- Prove pruning works: query history shows files/bytes scanned per query
-- ============================================================
SELECT statement_text, compute.warehouse_id AS warehouse_id, total_duration_ms, read_bytes, produced_rows
FROM system.query.history
WHERE statement_text ILIKE '%claims_fact%'
ORDER BY start_time DESC
LIMIT 10;

-- ============================================================
-- Point-lookup case: member_id equality predicate. Databricks mostly
-- folds Snowflake's Search Optimization Service use case into Liquid
-- Clustering + native file-level stats rather than shipping a parallel
-- service -- worth naming this explicitly if asked "what's the Databricks
-- equivalent of Snowflake SOS."
-- ============================================================
SELECT *
FROM healthcare_claims.gold_claims_ops.claims_fact
WHERE member_id = (SELECT member_id FROM healthcare_claims.gold_claims_ops.claims_fact LIMIT 1);
