# 🏥 Healthcare Claims & Loss Performance Platform

*End to End Healthcare Claims Pipeline with an Actuarial Reserving & Reinsurance Layer, on Databricks*

![Databricks](https://img.shields.io/badge/Databricks-Lakehouse-FF3621?style=flat&logo=databricks&logoColor=white)
![Delta Lake](https://img.shields.io/badge/Delta%20Lake-Storage-00ADD8?style=flat)
![Unity Catalog](https://img.shields.io/badge/Unity%20Catalog-Governance-00A1C9?style=flat)
![Lakeflow](https://img.shields.io/badge/Lakeflow-Declarative%20Pipelines-FF3621?style=flat)
![Streamlit](https://img.shields.io/badge/Streamlit-Dashboard-FF4B4B?style=flat&logo=streamlit&logoColor=white)
![Python](https://img.shields.io/badge/Python-3.11-3776AB?style=flat&logo=python&logoColor=white)

---

## 📑 Table of Contents

- [Business Problem](#-business-problem)
- [Overview](#-overview)
- [Dashboard](#-dashboard)
- [Architecture](#️-architecture)
- [Tech Stack](#️-tech-stack)
- [Dataset](#-dataset)
- [Pipeline Details](#️-pipeline-details)
- [Key Insights](#-key-insights)
- [Key Results](#-key-results)
- [Project Structure](#-project-structure)
- [Future Scope](#-future-scope)
- [Deployment Note](#-deployment-note)

---

## 🎯 Business Problem

Health insurers run two functions that rarely share a platform: **claims operations**, which processes and adjudicates individual claims, and **finance/actuarial**, which reserves for future liability and cedes risk to reinsurers. These teams need different data (PHI-adjacent claim detail vs. treaty economics and reserve estimates), different access controls, and usually end up on separate tools entirely, making it hard for either side to see the full financial picture of the book of business in one place.

**Use case:** A claims operations lead and a finance/actuarial analyst both need to answer questions from the same underlying data, without either seeing what the other shouldn't:

1. Is the book of business profitable? What's the loss ratio, and is it trending in the right direction?
2. Which regions, specialties, or providers are driving cost, and is a cost spike a one-off event or a pattern?
3. How much risk have we transferred to reinsurers, and how much reserve liability are we still holding?

This project demonstrates that exact workflow end to end: synthetic claims data flows through a governed medallion architecture, splits into persona-scoped Gold layers, and surfaces directly in an executive dashboard a finance lead could use to make a real underwriting or network-contracting decision. In this case, catching a 62% cost spike in one region during a three-month window, and confirming out-of-network care runs 57% more expensive per claim.

---

## 📘 Overview

This is a Databricks port and extension of a Snowflake healthcare-claims portfolio project, built to demonstrate the same architecture decisions expressed in Databricks-native primitives, with a **finance/actuarial module** layered on top: claim reserving (case reserves + IBNR) and reinsurance ceding (excess-of-loss and quota-share treaties modeled separately, since they pay out differently).

**Key Highlights:**

- 🏗️ Full Bronze-Silver-Gold medallion architecture on Unity Catalog, with Gold split into two schemas by persona (Claims Ops vs. Finance/Actuarial)
- 🔄 Lakeflow Declarative Pipelines with `APPLY CHANGES INTO` for SCD Type 1 (providers) and SCD Type 2 (members, treaties)
- ⚡ Liquid Clustering on the claims fact table, declared inline in the materialized view definition
- 🔐 Column-level PHI masking and a documented (though disabled-by-default, for a single-user account) row-level region filter
- 🤖 `ai_query()` against Databricks Foundation Model APIs for claim-note summarization and classification
- 📊 An executive Streamlit dashboard, deployed as a Databricks App, with every insight sentence computed live from the query result, not hardcoded
- 💰 Built and verified entirely on **Databricks Free Edition** at $0 cost. Documented in [`BUDGET_GUIDE.md`](./BUDGET_GUIDE.md)

---

## 📸 Dashboard

### KPIs and Loss Ratio Trend

![KPIs and Loss Ratio Trend](./screenshots/dashboard_01_kpi_loss_ratio.png)

The narrative sentence above the chart, *"average loss ratio of 0.71... highest point was 1.15 in August 2023"*, is generated from the query result at page-load time, not written by hand.

### Regional and Specialty Breakdown

![Regional and Specialty Breakdown](./screenshots/dashboard_02_region_specialty.png)

### Network Cost and Reinsurance

![Network Cost and Reinsurance](./screenshots/dashboard_03_network_reinsurance.png)

> **Note on public access:** Databricks Apps cannot be made publicly viewable. Anonymous, no-login sharing isn't supported on any tier. There's no live link to share here; the screenshots above are the actual, unedited output of the deployed app.

---

## 🏗️ Architecture

```
Source Systems (claims engine, enrollment, provider directory,
adjuster notes, reinsurance treaty register, premium billing)
       │
       ▼
Unity Catalog Volume (landing zone)  ──►  Auto Loader (cloudFiles)
       │
       ▼
Bronze Layer  ──►  8 raw tables, schema-on-read
       │
       ▼
Lakeflow Silver Layer  ──►  claims_staging, members_scd2 (SCD2),
                            providers_current (SCD1), claim_status_current,
                            reinsurance_treaties (SCD2), premium_ledger
       │
       ▼
Gold: Claims Ops                Gold: Finance / Actuarial
claims_fact (clustered,        reserves_fact, reinsurance_cession_fact,
PHI-masked), provider          loss_ratio_mart, combined_ratio_mart
performance, ai_query notes    (separate schema, separate grants)
       │
       ▼
Streamlit Dashboard (Databricks App)
```

Full diagram and the persona/access-split rationale: [`diagrams/architecture.md`](./diagrams/architecture.md).

---

## 🛠️ Tech Stack

| Layer | Technology |
|---|---|
| Storage & table format | Delta Lake |
| Governance & catalog | Unity Catalog (schemas, column masks, lineage) |
| Ingestion | Auto Loader (`cloudFiles`) |
| Transformation | Lakeflow Declarative Pipelines, PySpark |
| Compute | Databricks Serverless SQL Warehouse |
| AI / LLM | `ai_query()` against Databricks Foundation Model APIs |
| Visualization | Streamlit, deployed as a Databricks App |
| Language | Python 3.11, SQL |

---

## 📦 Dataset

- **Source:** fully synthetic, generated by [`data_generator.py`](./data_generator.py). No real PHI, ever
- **Size (at `--scale 0.001`, the budget-friendly default):** ~7,200 claims, ~690 member-plan-event rows, 25 providers, ~26,500 premium transactions
- **Calibration, not just randomness:** claim amounts, premium levels, and denial rates are deliberately calibrated against each other so the resulting loss ratio lands in a realistic ~0.65–0.85 band, rather than being arbitrary

> Three signals are deliberately built into the generator so the dashboard has real, explainable patterns to surface: a regional cost spike (Southeast/Southwest region, Q3 2023, a "flu season" story, ~1.8x severity and ~2.2x frequency), specialty-level denial rate variation, and an out-of-network cost multiplier (~1.6x). None of these are hardcoded into the dashboard's text. Every insight sentence is computed from whatever the data actually shows on a given run.

---

## ⚙️ Pipeline Details

### Bronze Layer

- Auto Loader (`cloudFiles`) reads parquet files from a Unity Catalog Volume landing zone into 8 Bronze tables
- Schema-on-read with a `_rescued_data` column, so upstream schema drift never breaks ingestion
- `.trigger(availableNow=True)`: processes whatever's currently landed, then stops cleanly

### Silver Layer

- `claims_staging`: typed, append-only streaming table (no CDC needed since Bronze claims are insert-only)
- `members_scd2`: `APPLY CHANGES INTO ... STORED AS SCD TYPE 2`. A claim must be judged against the plan a member had on the date of service, so history matters
- `providers_current`: `STORED AS SCD TYPE 1`. No history needed, network status just changes in place
- `reinsurance_treaties`: SCD Type 2. A cession must use the treaty terms in force on the claim date, not this year's renegotiated terms

### Gold Layer: Claims Ops

- `claims_fact`: the joined, curated fact table, Liquid Clustered on `(claim_date, provider_id)`, with `diagnosis_code` masked inline in the `SELECT` (PHI protection)
- `provider_performance_mart`: denial rate and billed amount by provider
- `claim_notes_enriched`: `ai_query()`-generated summaries and category classifications of adjuster notes

### Gold Layer: Finance / Actuarial

- `reserves_fact`: case reserve + IBNR at a `(claim, valuation_date)` grain, modeled as its own fact table since reserves are re-estimated periodically, not a static claim attribute
- `reinsurance_cession_fact`: excess-of-loss and quota-share modeled with genuinely different formulas, since they pay out differently
- `loss_ratio_mart` / `combined_ratio_mart`: incurred losses and earned premium are aggregated independently, then joined by period, so the ratio reflects true population-level totals

---

## 🔎 Key Insights

From the live dashboard, computed dynamically at page-load time (numbers will vary slightly run to run, since the synthetic generator reseeds):

- The book runs at an average loss ratio of **0.71**, within a healthy range, with a clear spike to **1.15** during a regional cost event in **August 2023**
- **Southwest** carries the largest share of claims cost at **23%** of the total in this run
- **Primary Care** has the highest denial rate at **16%**, a candidate for a documentation or prior-authorization review
- Out-of-network claims cost **57% more** on average than in-network care
- **9.4%** of incurred losses have been transferred to reinsurers, reducing net retained risk

---

## 📈 Key Results

| Metric | Value |
|---|---|
| Total Claims | 7,202 |
| Total Incurred | $6,140,720 |
| Ceded to Reinsurance | $574,198 |
| Total Reserves Held | $1,680,983 |
| Average Loss Ratio | 0.71 |
| Peak Loss Ratio | 1.15 (Aug 2023) |
| Highest-Cost Region | Southwest (23% of total) |
| Highest Denial Rate | Primary Care (16%) |
| Out-of-Network Cost Premium | +57% vs. in-network |

---

## 📂 Project Structure

```
databricks-healthcare-finance-claims/
├── README.md
├── BUDGET_GUIDE.md
├── data_generator.py
├── screenshots/
│   ├── dashboard_01_kpi_loss_ratio.png
│   ├── dashboard_02_region_specialty.png
│   └── dashboard_03_network_reinsurance.png
├── notebooks/
│   ├── 01_setup_catalog_schemas.sql
│   ├── 02_bronze_ingestion.py
│   ├── 03_silver_transformations.sql
│   ├── 04_gold_claims_ops.sql
│   ├── 05_liquid_clustering_perf.sql
│   ├── 06_unity_catalog_governance.sql
│   ├── 07_finance_reserving.sql
│   ├── 07b_finance_reserving_pyspark.py
│   ├── 08_ai_query_claim_notes.sql
│   ├── 09_cost_monitoring_finops.sql
│   └── 10_time_travel_cloning.sql
├── pipelines/
│   └── lakeflow_pipeline.yml
├── diagrams/
│   └── architecture.md
└── streamlit_dashboard/
    ├── app.py
    ├── app.yaml
    └── requirements.txt
```

---

## 🔭 Future Scope

- Surface the `ibnr_by_service_month` table (built in `07b_finance_reserving_pyspark.py`, computed but not yet visualized) as a reserve-development chart on the dashboard
- Regenerate the synthetic dataset at a larger `--scale` to give every specialty a statistically stable sample size, the current small-sample run occasionally shows noisy denial rates for lower-volume specialties
- Add Lakeflow data-quality expectations (`EXPECT ... ON VIOLATION`) to every Silver table
- Real Unity Catalog groups and enabled row-level security on the finance marts, not provisionable on a single-user Free Edition account, but fully designed and documented
- A proper actuarial review of the IBNR chain-ladder methodology, which is illustrative, not filing-grade

---

## 📌 Deployment Note

This project is designed to run entirely on **Databricks Free Edition** at zero cost. Generate synthetic data locally (`python data_generator.py --out ./synthetic_data --scale 0.001`), upload it to a Unity Catalog Volume, then work through the notebooks in `notebooks/` in numbered order. The Streamlit dashboard deploys as a Databricks App from the `streamlit_dashboard/` folder, with a SQL Warehouse resource attached.

Full step-by-step budget guidance: [`BUDGET_GUIDE.md`](./BUDGET_GUIDE.md).

---

*Built with Databricks · Delta Lake · Unity Catalog · Lakeflow Declarative Pipelines · PySpark · Streamlit · Databricks Apps*
