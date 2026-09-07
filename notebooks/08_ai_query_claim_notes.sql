-- 08_ai_query_claim_notes.sql
-- ai_query() against Databricks Foundation Model APIs -- direct replacement
-- for Snowflake Cortex AI functions (SUMMARIZE, SENTIMENT, COMPLETE).
--
-- Why ai_query() instead of calling an external LLM API from a notebook?
-- PHI-adjacent text never leaves Unity Catalog's governance boundary --
-- the same row/column-level access controls that protect claims_fact apply
-- to what a query can even send to the model, and there's no data egress to
-- an external vendor. That's the reason regulated industries (healthcare,
-- insurance, finance) reach for this over an external API call, and it's
-- worth saying as one sentence rather than listing model names.
--
-- NOTE FOR FREE EDITION: model serving is quota-limited per day (fair-use
-- policy), so keep LIMIT clauses small -- a handful of calls is enough to
-- demonstrate the pattern without risking a daily compute lockout.

-- ============================================================
-- Summarize free-text adjuster notes
-- ============================================================
SELECT
  claim_id,
  ai_query(
    'databricks-meta-llama-3-3-70b-instruct',
    CONCAT('Summarize this claim adjuster note in one sentence: ', note_text)
  ) AS note_summary
FROM healthcare_claims.silver.claim_notes
LIMIT 10;

-- ============================================================
-- Classify denial root cause in a few words
-- ============================================================
SELECT
  claim_id,
  ai_query(
    'databricks-meta-llama-3-3-70b-instruct',
    CONCAT('Given this denial note, classify the likely root cause in 3 words: ', note_text)
  ) AS root_cause
FROM healthcare_claims.silver.claim_notes
WHERE note_text ILIKE '%denied%'
LIMIT 10;

-- ============================================================
-- Sentiment / urgency flag (useful for prioritizing appeals review queue)
-- ============================================================
SELECT
  claim_id,
  ai_query(
    'databricks-meta-llama-3-3-70b-instruct',
    CONCAT('Rate the urgency of this claim note as low, medium, or high. Respond with one word: ', note_text)
  ) AS urgency
FROM healthcare_claims.silver.claim_notes
WHERE note_text ILIKE '%appeal%'
LIMIT 10;

-- Note: production usage of this pattern belongs in the scheduled
-- materialized view healthcare_claims.gold_claims_ops.claim_notes_enriched
-- (see 04_gold_claims_ops.sql) rather than ad-hoc queries, so the enrichment
-- refreshes on the same cadence as the rest of the Gold layer.
