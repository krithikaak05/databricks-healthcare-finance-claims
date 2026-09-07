-- 06_unity_catalog_governance.sql
-- RBAC, column masking, and row-level filtering via Unity Catalog.
-- Direct replacement for Snowflake RBAC + dynamic data masking + row
-- access policies.
--
-- NOTE: column masks and row filters attached via
-- ALTER TABLE ... SET MASK / SET ROW FILTER only work on plain Delta
-- tables, NOT on Lakeflow-managed materialized views or streaming tables
-- (they enforce a "must be a table" restriction, the same one hit with
-- CLUSTER BY and DESCRIBE DETAIL elsewhere in this project). Since
-- claims_fact, reserves_fact, and reinsurance_cession_fact are all
-- materialized views, their masking/filtering logic is instead embedded
-- directly in each view's own SELECT statement -- see 04_gold_claims_ops.sql
-- (diagnosis_code masking) and 07_finance_reserving.sql (region row-filter,
-- documented but disabled by default -- see that file's comments on why).
-- The GRANT and CREATE FUNCTION statements below still apply as-is to
-- plain tables, and the reasoning is identical either way.

-- ============================================================
-- Grants: two personas, two Gold schemas
-- ============================================================
GRANT USE CATALOG ON CATALOG healthcare_claims TO `claims_analyst`;
GRANT USE CATALOG ON CATALOG healthcare_claims TO `finance_analyst`;

GRANT USE SCHEMA, SELECT ON SCHEMA healthcare_claims.gold_claims_ops TO `claims_analyst`;
GRANT USE SCHEMA, SELECT ON SCHEMA healthcare_claims.gold_claims_ops TO `claims_admin`;
GRANT ALL PRIVILEGES ON SCHEMA healthcare_claims.gold_claims_ops TO `claims_admin`;

GRANT USE SCHEMA, SELECT ON SCHEMA healthcare_claims.gold_finance TO `finance_analyst`;
GRANT ALL PRIVILEGES ON SCHEMA healthcare_claims.gold_finance TO `finance_admin`;

-- ============================================================
-- Column masking function -- reusable, referenced directly inside
-- claims_fact's SELECT statement (see 04_gold_claims_ops.sql) since the
-- view can't be ALTERed after the fact.
-- ============================================================
CREATE OR REPLACE FUNCTION healthcare_claims.gold_claims_ops.mask_diagnosis(diagnosis_code STRING)
RETURNS STRING
COMMENT 'Masks diagnosis_code unless caller is in phi_viewer or claims_admin group.'
RETURN CASE
  WHEN is_account_group_member('phi_viewer') OR is_account_group_member('claims_admin')
    THEN diagnosis_code
  ELSE '***MASKED***'
END;

-- Reference implementation for a PLAIN TABLE (not a materialized view):
-- ALTER TABLE some_plain_table ALTER COLUMN diagnosis_code
--   SET MASK healthcare_claims.gold_claims_ops.mask_diagnosis;

-- ============================================================
-- Row filter function -- reference implementation for a plain table.
-- The finance marts in this project are materialized views, so this
-- exact filter is embedded (commented out by default) inside
-- 07_finance_reserving.sql instead of applied via ALTER TABLE.
-- ============================================================
CREATE OR REPLACE FUNCTION healthcare_claims.gold_finance.region_row_filter(region STRING)
RETURNS BOOLEAN
COMMENT 'Restricts rows to the caller region group unless caller is finance_admin.'
RETURN is_account_group_member('finance_admin') OR is_account_group_member(region);

-- ALTER TABLE some_plain_table SET ROW FILTER
--   healthcare_claims.gold_finance.region_row_filter ON (region);

-- ============================================================
-- Verify: audit who can see what
-- ============================================================
SHOW GRANTS ON SCHEMA healthcare_claims.gold_claims_ops;
SHOW GRANTS ON SCHEMA healthcare_claims.gold_finance;
DESCRIBE FUNCTION EXTENDED healthcare_claims.gold_claims_ops.mask_diagnosis;

-- ============================================================
-- Column-level lineage: shows every downstream table/view that reads
-- diagnosis_code -- practical proof that masking propagates through every
-- derived mart, useful during a compliance review.
-- ============================================================
SELECT source_table_full_name, source_column_name, target_table_full_name, target_column_name
FROM system.access.column_lineage
WHERE source_column_name = 'diagnosis_code';
