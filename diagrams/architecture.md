# Architecture Diagram (source of truth)

```
+---------------------------------------------------------------+
|                     SOURCE SYSTEMS                             |
|  Claims engine, Enrollment system, Provider directory,         |
|  Claim adjuster notes (unstructured), Reinsurance treaty        |
|  register, Premium billing system                              |
+------------------------------+----------------------------------+
                               |  Unity Catalog Volume (landing zone)
                               |  Auto Loader (cloudFiles)
                               v
+---------------------------------------------------------------+
|  BRONZE  -- raw landing, schema-on-read, as-is                  |
|  catalog: healthcare_claims.bronze                              |
+------------------------------+----------------------------------+
                               |  Lakeflow Declarative Pipelines
                               |  (APPLY CHANGES INTO / streaming tables)
                               v
+---------------------------------------------------------------+
|  SILVER  -- cleaned, typed, deduped                              |
|  SCD Type 2 on members, SCD Type 1 on providers,                |
|  reinsurance treaty dimension, premium ledger                   |
|  catalog: healthcare_claims.silver                               |
+------------------------------+----------------------------------+
                               |  Lakeflow materialized views
                               v
+----------------------------+   +--------------------------------+
|  GOLD -- CLAIMS OPS         |   |  GOLD -- FINANCE / ACTUARIAL     |
|  claims_fact (liquid        |   |  reserves_fact (case + IBNR)     |
|  clustered + inline PHI     |   |  reinsurance_cession_fact         |
|  masking), provider          |   |  loss_ratio_mart, combined_ratio  |
|  performance marts,          |   |  (separate Gold schema + separate |
|  ai_query-enriched notes    |   |   Unity Catalog grants)           |
+----------------------------+   +--------------------------------+
                               |
                               v
                    +----------------------+
                    |  Streamlit Dashboard  |
                    |  (Databricks App)     |
                    +----------------------+
```

## Persona / access split

```
                     +---------------------+
                     |   Unity Catalog      |
                     |  healthcare_claims    |
                     +----------+------------+
              +-----------------+------------------+
              v                                     v
  gold_claims_ops schema                   gold_finance schema
  ---------------------                    ---------------------
  claims_analyst   (SELECT)                finance_analyst (SELECT)
  phi_viewer       (unmasked diagnosis)    finance_admin   (ALL)
  claims_admin     (ALL)
```

## Why two Gold schemas instead of one

- **Different sensitivity dimension.** PHI (diagnosis codes) vs. financial/treaty
  economics (attachment points, cession %, reserve estimates) are protected
  for different reasons and against different risks.
- **Different audience.** Claims Operations doesn't need treaty economics;
  Finance/Actuarial usually doesn't need raw diagnosis codes.
- **Grants scale by schema, not by table.** New tables added to either schema
  inherit the right default access pattern automatically.

## Real-world lessons learned building this on Databricks Free Edition

- **Materialized views and streaming tables are not plain Delta tables.**
  `ALTER TABLE ... CLUSTER BY`, `DESCRIBE DETAIL`, `SET MASK`, `SET ROW FILTER`,
  and `SHALLOW CLONE` all fail on them with "expects a table but is a view"
  errors. The workaround: declare `CLUSTER BY` directly in the `CREATE
  MATERIALIZED VIEW` statement, and embed masking/row-filter logic directly
  in the view's `SELECT` clause instead of altering it afterward.
- **A row-level or column-level join can silently corrupt an aggregate.**
  An early version of `loss_ratio_mart` joined claims to premiums row-by-row,
  which fanned out and double-counted premium for any member with multiple
  claims in a month -- collapsing the loss ratio down to roughly (avg claim
  amount / avg monthly premium) instead of a true population-level ratio.
  Fix: aggregate each side independently, then join the two monthly totals.
- **Streaming sources are append-only by contract.** A `DELETE` on a Bronze
  table feeding a Lakeflow streaming table breaks the pipeline with a
  `DELTA_SOURCE_IGNORE_DELETE` error. Recovery requires a Full Refresh, not
  an incremental run.
- **Auto Loader checkpoints remember filenames, not table state.** Deleting
  rows from a Bronze table without also pointing Auto Loader at a fresh
  checkpoint path means it silently skips files it thinks it already
  processed, even though the table is now empty.
- **Databricks system table schemas vary by workspace tier and change over
  time.** `system.query.history`'s warehouse ID lives inside a nested
  `compute` struct, not as a top-level column; `system.compute.clusters`
  uses `auto_termination_minutes` (with an underscore) and omits
  `node_type_id` entirely on serverless-only tiers.
- **Databricks Apps cannot be made public.** Anonymous, no-login sharing
  isn't supported -- viewers need a Databricks account and explicit
  permission, even on a free tier.
