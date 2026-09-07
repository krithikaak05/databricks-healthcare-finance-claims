-- 04_gold_claims_ops.sql
-- Gold layer materialized views for the Claims Operations persona.
-- Direct replacement for Snowflake Dynamic Tables.
--
-- Why materialized views instead of APPLY CHANGES INTO here?
-- This join is a pure declarative transformation -- no custom upsert/merge
-- logic needed. Lakeflow materialized views let the engine figure out the
-- incremental refresh plan itself, same "one knob instead of hand-written
-- merge logic" story as Snowflake Dynamic Tables' TARGET_LAG. Reach for
-- APPLY CHANGES INTO (as in 03_silver_transformations.sql) when you need
-- custom CDC/SCD logic; reach for a materialized view when you don't.
--
-- NOTE ON CLUSTERING: claims_fact is a Lakeflow-managed materialized view,
-- not a plain Delta table -- ALTER TABLE ... CLUSTER BY doesn't apply to
-- views. Liquid Clustering is declared directly in the view's CREATE
-- statement below via CLUSTER BY, right where the view is defined.

CREATE OR REFRESH MATERIALIZED VIEW healthcare_claims.gold_claims_ops.claims_fact
COMMENT 'Curated claims fact table, joined as-of the claim date against the SCD2 member dimension.'
CLUSTER BY (claim_date, provider_id)
AS
SELECT
  c.claim_id,
  c.member_id,
  m.plan_type,
  m.region,
  c.provider_id,
  p.specialty,
  p.network_status,
  c.claim_date,
  c.claim_amount,
  s.status AS claim_status,
  CASE
    WHEN is_account_group_member('phi_viewer') OR is_account_group_member('claims_admin')
      THEN c.diagnosis_code
    ELSE '***MASKED***'
  END AS diagnosis_code
FROM healthcare_claims.silver.claims_staging c
JOIN healthcare_claims.silver.members_scd2 m
  ON c.member_id = m.member_id
 AND c.claim_date BETWEEN m.effective_date AND COALESCE(m.__END_AT, DATE'9999-12-31')
JOIN healthcare_claims.silver.providers_current p
  ON c.provider_id = p.provider_id
LEFT JOIN healthcare_claims.silver.claim_status_current s
  ON c.claim_id = s.claim_id;

-- Why is diagnosis_code masked inline in the view's SELECT, instead of via
-- ALTER TABLE ... ALTER COLUMN ... SET MASK (the approach used for a plain
-- Delta table)?
-- claims_fact is a Lakeflow-managed materialized view, not a plain table --
-- Unity Catalog's ALTER TABLE-based masking API expects a table object, the
-- same restriction we hit with CLUSTER BY. The masking RULE is identical
-- either way (unless phi_viewer/claims_admin group membership, show
-- ***MASKED***) -- only the mechanism for attaching it differs. On a plain
-- Delta table, prefer the ALTER TABLE ... SET MASK approach (see
-- 06_unity_catalog_governance.sql) since the rule then travels with the
-- column across every downstream consumer automatically; embedding it in a
-- view's SELECT, as done here, means every future view built on top of this
-- one needs its own re-statement of the same rule -- worth naming that
-- trade-off explicitly if asked about it.

-- Note: __END_AT is the Lakeflow-managed SCD2 validity-end column produced
-- by APPLY CHANGES INTO ... STORED AS SCD TYPE 2. Confirm the exact system
-- column name against your pipeline's schema (it may be surfaced as
-- __END_AT or a name you alias explicitly in the APPLY CHANGES statement).

-- ============================================================
-- Provider performance mart -- classic Claims Ops dashboard source
-- ============================================================
CREATE OR REFRESH MATERIALIZED VIEW healthcare_claims.gold_claims_ops.provider_performance_mart
AS
SELECT
  provider_id,
  specialty,
  network_status,
  COUNT(*)                                   AS total_claims,
  SUM(claim_amount)                          AS total_billed,
  SUM(CASE WHEN claim_status = 'denied' THEN 1 ELSE 0 END) AS denied_claims,
  ROUND(SUM(CASE WHEN claim_status = 'denied' THEN 1 ELSE 0 END) * 1.0 / COUNT(*), 4) AS denial_rate
FROM healthcare_claims.gold_claims_ops.claims_fact
GROUP BY provider_id, specialty, network_status;

-- ============================================================
-- Claim notes enriched with ai_query() summaries -- see 08_ai_query_claim_notes.sql
-- for the standalone exploration version; this materialized view is the
-- production-scheduled equivalent, refreshed as part of the same pipeline.
-- ============================================================
CREATE OR REFRESH MATERIALIZED VIEW healthcare_claims.gold_claims_ops.claim_notes_enriched
AS
SELECT
  n.claim_id,
  n.note_text,
  n.note_date,
  ai_query(
    'databricks-meta-llama-3-3-70b-instruct',
    CONCAT('Summarize this claim adjuster note in one sentence: ', n.note_text)
  ) AS note_summary,
  ai_query(
    'databricks-meta-llama-3-3-70b-instruct',
    CONCAT('Classify this note as one of: routine, denial, appeal, fraud_flag. Respond with one word: ', n.note_text)
  ) AS note_category
FROM healthcare_claims.silver.claim_notes n;
