# Running This on a Budget (Free / Near-Free)

This project was built and fully verified end-to-end on **Databricks Free Edition** — no credit card, no time limit.

## What Free Edition gives you
- Unity Catalog: full features (masks, row filters embedded in views, lineage) — one metastore
- One SQL Warehouse, capped at `2X-Small`
- One active Lakeflow Declarative Pipeline per type
- Serverless notebook compute (daily fair-use quota)
- Limited serverless model serving (covers `ai_query()`)
- Up to 3 Databricks Apps

## What it doesn't allow
Custom clusters, your own cloud storage bucket wired directly into Auto Loader (use a Unity Catalog Volume instead — see `01_setup_catalog_schemas.sql`), and unlimited daily compute (you get a hard quota that resets daily).

## Practical run size
Generate synthetic data at a small scale to stay well within a day's compute quota:
```bash
python data_generator.py --out ./synthetic_data --scale 0.001
```
This produces ~7,000-8,000 claims and everything downstream sized proportionally — enough to prove every architectural concept correctly, without risking the daily `RESOURCE_EXHAUSTED` compute lockout.

## If you hit the daily quota
You'll see a `RESOURCE_EXHAUSTED` message when trying to start a warehouse or cluster. Nothing is lost — your catalog, schemas, tables, and uploaded data are untouched. Compute resumes when the daily quota resets (usually within the same day).

## Total realistic cost
**$0.** Every step in this README — Bronze through the live Streamlit dashboard — was run and verified on Free Edition alone.
