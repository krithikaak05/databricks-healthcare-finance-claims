-- 09_cost_monitoring_finops.sql
-- Cost visibility and governance using Databricks system tables. Direct
-- replacement for Snowflake ACCOUNT_USAGE.QUERY_HISTORY /
-- WAREHOUSE_METERING_HISTORY / WAREHOUSE_LOAD_HISTORY + Resource Monitors.
--
-- NOTE FOR FREE EDITION: system.* tables may have restricted access outside
-- paid workspaces (no account console, limited admin visibility). Try each
-- block below -- if one errors out or returns empty, that's expected on
-- this tier, not a bug in the SQL. Run one block at a time.

-- ============================================================
-- Most expensive queries this week
-- ============================================================
SELECT
  statement_text,
  warehouse_id,
  executed_by,
  total_duration_ms / 1000.0 AS total_duration_sec,
  read_bytes,
  produced_rows
FROM system.query.history
WHERE start_time > current_timestamp() - INTERVAL 7 DAYS
ORDER BY total_duration_ms DESC
LIMIT 20;

-- ============================================================
-- Compute spend by day, by SKU (warehouse vs. jobs vs. serverless)
-- ============================================================
SELECT
  usage_date,
  sku_name,
  SUM(usage_quantity) AS dbus
FROM system.billing.usage
WHERE usage_date > current_date() - INTERVAL 30 DAYS
GROUP BY 1, 2
ORDER BY usage_date DESC, dbus DESC;

-- ============================================================
-- Idle / misconfigured cluster detection -- clusters with no
-- auto-termination set are the #1 cause of runaway lakehouse spend, same
-- as an oversized always-on Snowflake warehouse.
-- ============================================================
SELECT cluster_id, cluster_name, autotermination_minutes, node_type_id
FROM system.compute.clusters
WHERE autotermination_minutes IS NULL OR autotermination_minutes = 0;

-- ============================================================
-- Lakeflow pipeline run cost/duration -- catch a pipeline whose refresh
-- time (and therefore cost) is silently creeping up
-- ============================================================
SELECT
  pipeline_id,
  pipeline_name,
  start_time,
  end_time,
  (unix_timestamp(end_time) - unix_timestamp(start_time)) AS duration_sec
FROM system.lakeflow.pipeline_runs
WHERE start_time > current_timestamp() - INTERVAL 30 DAYS
ORDER BY duration_sec DESC
LIMIT 20;

-- ============================================================
-- Hard guardrails (configured outside SQL, listed here for reference):
--   1. Cluster policy on load_wh / transform_wh enforcing:
--        - max autoscale node count
--        - mandatory autotermination_minutes <= 15
--        - approved instance types only
--   2. Budget policy (account console) with a monthly DBU/spend threshold,
--      alerting at 75% and blocking new cluster starts for the tagged
--      project at 100% -- this is the direct equivalent of a Snowflake
--      Resource Monitor's "notify at 75%, suspend at 100%" pattern.
--   On Free Edition, both of these require account-console access you
--   likely don't have -- cite this as the design you'd apply once
--   promoted to a paid workspace, rather than something to configure here.
-- ============================================================
