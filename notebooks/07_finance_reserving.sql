-- 07_finance_reserving.sql
-- Finance / Actuarial module: claim reserving + reinsurance ceding + loss
-- ratio marts. This is the layer added on top of the base healthcare claims
-- platform to give it a genuine finance/actuarial story, not just claims
-- operations.
--
-- Lives in healthcare_claims.gold_finance -- a separate schema from
-- gold_claims_ops with separate grants (see 06_unity_catalog_governance.sql).
-- Why separate? Reserve methodology and treaty economics are financially
-- sensitive in a different way than PHI is sensitive, and the audience
-- (finance/actuarial) is different from Claims Operations. Bolting these
-- columns onto claims_fact would force everyone with claims_fact access to
-- also see treaty terms, which defeats the point of persona-scoped access.
--
-- NOTE ON ROW-LEVEL SECURITY: reserves_fact and reinsurance_cession_fact
-- are Lakeflow-managed materialized views, not plain Delta tables --
-- ALTER TABLE ... SET ROW FILTER expects a table object and fails on views
-- with the same restriction encountered with CLUSTER BY on claims_fact.
-- The region-based access rule is instead embedded directly as a WHERE
-- clause using is_account_group_member() in each view's own SELECT --
-- functionally equivalent, though (as with the diagnosis_code mask on
-- claims_fact) any future view built on top would need to re-state the
-- same rule rather than inheriting it automatically the way a table-level
-- ROW FILTER would propagate.

-- ============================================================
-- Reserves fact: case reserve + IBNR, at a (claim, valuation_date) grain
-- Why its own fact table with a valuation_date grain, instead of a column
-- on claims_fact?
-- Reserves are RE-ESTIMATED every valuation period (typically monthly),
-- even for claims that haven't otherwise changed -- it's a periodically
-- re-computed liability estimate, not a static claim attribute. Modeling it
-- with a valuation_date grain lets you track reserve DEVELOPMENT over time
-- (a real actuarial deliverable -- a "reserve triangle") without mutating
-- claim history each time an estimate changes.
-- ============================================================
CREATE OR REFRESH MATERIALIZED VIEW healthcare_claims.gold_finance.reserves_fact
COMMENT 'Case reserve + IBNR estimate per claim per monthly valuation date.'
AS
SELECT
  r.claim_id,
  r.valuation_date,
  r.case_reserve,
  r.ibnr_reserve,
  r.case_reserve + r.ibnr_reserve AS total_reserve,
  m.region
FROM healthcare_claims.silver.reserves_typed r
JOIN healthcare_claims.gold_claims_ops.claims_fact c
  ON r.claim_id = c.claim_id
JOIN healthcare_claims.silver.members_scd2 m
  ON c.member_id = m.member_id
 AND c.claim_date BETWEEN m.effective_date AND COALESCE(m.__END_AT, DATE'9999-12-31');

-- ROW-LEVEL SECURITY, DELIBERATELY NOT APPLIED ABOVE:
-- The design calls for restricting rows to the caller's own region unless
-- they're finance_admin, e.g.:
--   WHERE is_account_group_member('finance_admin') OR is_account_group_member(m.region)
-- This is left OUT of the live view above on purpose: a single-user Free
-- Edition account has no custom account groups configured (no admin
-- console access on the free tier), so is_account_group_member() would
-- evaluate false for every row and silently return an EMPTY table --
-- indistinguishable from a broken pipeline. Add the WHERE clause back once
-- real finance_admin / region groups exist in your account (paid workspace
-- or an admin-enabled tier), and cite this exact filter in an interview:
-- it's the same one used for masking claims_fact.diagnosis_code, just
-- scoping rows instead of scoping a column's contents.

-- IBNR triangle-style projections that require windowed cohort math live in
-- 07b_finance_reserving_pyspark.py -- that logic is genuinely procedural
-- (reporting-lag cohorts), not a clean single SQL statement, same
-- "why PySpark over pure SQL" justification as Snowpark risk-scoring in the
-- original project.

-- ============================================================
-- Reinsurance cession fact: excess-of-loss and quota-share treaties
-- Why model the two treaty types with different formulas instead of one
-- generic "cession %" column?
-- They are genuinely different risk-transfer mechanics. Excess-of-loss only
-- cedes the slice of a claim ABOVE an attachment point (protects against
-- large individual losses). Quota-share cedes a flat percentage of EVERY
-- claim regardless of size (protects against aggregate volume). Collapsing
-- both into one percentage column would misrepresent how the treaties
-- actually pay out -- an actuarial reviewer would flag this immediately.
-- ============================================================
CREATE OR REFRESH MATERIALIZED VIEW healthcare_claims.gold_finance.reinsurance_cession_fact
COMMENT 'Per-claim ceded amount under the applicable reinsurance treaty, by treaty type.'
AS
SELECT
  c.claim_id,
  t.treaty_id,
  t.treaty_type,
  t.reinsurer_name,
  c.claim_amount,
  t.attachment_point,
  t.treaty_limit,
  t.cession_pct,
  CASE
    WHEN t.treaty_type = 'excess_of_loss' THEN
      GREATEST(0, LEAST(c.claim_amount, t.attachment_point + t.treaty_limit) - t.attachment_point)
    WHEN t.treaty_type = 'quota_share' THEN
      c.claim_amount * t.cession_pct
    ELSE 0
  END AS ceded_amount,
  m.region
FROM healthcare_claims.gold_claims_ops.claims_fact c
JOIN healthcare_claims.silver.reinsurance_treaties t
  ON c.claim_date BETWEEN t.effective_date AND COALESCE(t.expiry_date, DATE'9999-12-31')
JOIN healthcare_claims.silver.members_scd2 m
  ON c.member_id = m.member_id
 AND c.claim_date BETWEEN m.effective_date AND COALESCE(m.__END_AT, DATE'9999-12-31');

-- Same row-level security note as reserves_fact above: the region-based
-- WHERE filter is deliberately omitted here for the same reason -- it
-- would silently zero out this table on a single-user Free Edition account
-- with no custom groups configured. Add it back once real groups exist.

-- ============================================================
-- Loss ratio mart: incurred losses / earned premium, by month
-- Why this mart matters for the interview story: loss ratio (and combined
-- ratio once expense data is added) is the headline metric an insurer's
-- finance team reports externally. Building the pipeline all the way to a
-- metric a CFO actually reads is a stronger story than stopping at a raw
-- fact table.
--
-- WHY TWO SEPARATE CTEs INSTEAD OF A DIRECT JOIN:
-- Joining claims_fact to premium_ledger row-by-row (one row per claim,
-- matched to that member's premium row for the month) causes a silent
-- fan-out bug: a member with 2 claims in the same month has their single
-- monthly premium counted TWICE in the sum, because the join produces one
-- output row per claim, not per member. That collapses the ratio down to
-- roughly (average claim amount / average monthly premium per member) --
-- a number driven by claim frequency, not by the true premium base across
-- the whole population. Aggregating incurred losses and earned premium
-- INDEPENDENTLY first (each grouped by month, with no row-level join to
-- claims at all) and only then joining the two monthly totals avoids this
-- entirely -- earned_premium correctly reflects every member's premium
-- for that month exactly once, regardless of how many claims they filed.
-- ============================================================
CREATE OR REFRESH MATERIALIZED VIEW healthcare_claims.gold_finance.loss_ratio_mart
AS
WITH incurred AS (
  SELECT
    DATE_TRUNC('month', claim_date) AS period,
    SUM(claim_amount) AS incurred_losses
  FROM healthcare_claims.gold_claims_ops.claims_fact
  GROUP BY 1
),
earned AS (
  SELECT
    DATE_TRUNC('month', period_date) AS period,
    SUM(premium_amount) AS earned_premium
  FROM healthcare_claims.silver.premium_ledger
  GROUP BY 1
)
SELECT
  i.period,
  i.incurred_losses,
  e.earned_premium,
  ROUND(i.incurred_losses / NULLIF(e.earned_premium, 0), 4) AS loss_ratio
FROM incurred i
JOIN earned e ON i.period = e.period;

-- ============================================================
-- Combined ratio mart: loss ratio + expense ratio (expense data placeholder --
-- in a real build this joins to a claims-adjustment-expense ledger; kept as
-- a simple illustrative extension here)
-- ============================================================
CREATE OR REFRESH MATERIALIZED VIEW healthcare_claims.gold_finance.combined_ratio_mart
AS
SELECT
  period,
  loss_ratio,
  0.22 AS expense_ratio_assumed,  -- placeholder: replace with real expense ledger join
  ROUND(loss_ratio + 0.22, 4) AS combined_ratio
FROM healthcare_claims.gold_finance.loss_ratio_mart;

-- A combined ratio under 1.0 means underwriting profit before investment
-- income; over 1.0 means the book is losing money on underwriting alone.
-- Worth being able to say that sentence out loud in an interview.
