"""
Healthcare Claims + Finance Platform -- Executive Dashboard

Runs as a Databricks App (Streamlit). Connects to the SQL Warehouse attached
to this app via Databricks' built-in OAuth -- no manual token management.

Deploy: Compute -> Apps -> Create App -> Streamlit template, then replace
the generated app.py/requirements.txt/app.yaml with these files, attach a
SQL Warehouse resource to the app (this injects the env vars this script
reads), and deploy.
"""

import os
from decimal import Decimal

import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import streamlit as st
from databricks import sql
from databricks.sdk.core import Config

st.set_page_config(page_title="Healthcare Claims + Finance Platform", layout="wide")

CATALOG = "healthcare_claims"


# ---------------------------------------------------------------------------
# Connection
# ---------------------------------------------------------------------------
@st.cache_resource
def get_connection():
    cfg = Config()  # auto-detects the app's OAuth credentials when running
    # inside Databricks Apps -- no token needs to be hardcoded here.
    # Fallback to a known warehouse ID if the resource-injected env var
    # isn't present -- some Databricks Apps deployments (notably on
    # certain Free Edition workspaces) don't reliably inject
    # DATABRICKS_WAREHOUSE_ID even when a SQL Warehouse resource is
    # correctly attached. Find your own warehouse's ID under
    # SQL Warehouses -> [your warehouse] -> Connection details -> HTTP path
    # (the ID is the last segment, e.g. /sql/1.0/warehouses/<THIS PART>).
    warehouse_id = os.environ.get("DATABRICKS_WAREHOUSE_ID") or "0abf7ad75a52c509"
    return sql.connect(
        server_hostname=cfg.host,
        http_path=f"/sql/1.0/warehouses/{warehouse_id}",
        credentials_provider=lambda: cfg.authenticate,
    )


@st.cache_data(ttl=300)
def run_query(query: str) -> pd.DataFrame:
    conn = get_connection()
    with conn.cursor() as cursor:
        cursor.execute(query)
        cols = [c[0] for c in cursor.description]
        rows = cursor.fetchall()
    df = pd.DataFrame(rows, columns=cols)
    # The Databricks SQL connector returns DECIMAL columns (SUM/AVG results)
    # as Python Decimal objects, not floats -- Python raises a TypeError if
    # you mix Decimal and float in arithmetic (e.g. computing a percentage).
    # Converting every Decimal to float here, once, means none of the
    # downstream narrative-insight calculations need to worry about it.
    for col in df.columns:
        df[col] = df[col].apply(lambda v: float(v) if isinstance(v, Decimal) else v)
    return df


# ---------------------------------------------------------------------------
# Queries
# Note on loss ratio: computed here directly with claims and premiums
# aggregated INDEPENDENTLY (not row-joined) to avoid the fan-out bug found
# in an earlier version of the materialized view -- see project README for
# the full writeup. This keeps the dashboard correct regardless of whether
# the underlying mart has been rebuilt yet.
# ---------------------------------------------------------------------------
LOSS_RATIO_SQL = f"""
WITH incurred AS (
  SELECT DATE_TRUNC('month', claim_date) AS period, SUM(claim_amount) AS incurred_losses
  FROM {CATALOG}.gold_claims_ops.claims_fact
  GROUP BY 1
),
earned AS (
  SELECT DATE_TRUNC('month', period_date) AS period, SUM(premium_amount) AS earned_premium
  FROM {CATALOG}.silver.premium_ledger
  GROUP BY 1
)
SELECT i.period, i.incurred_losses, e.earned_premium,
       ROUND(i.incurred_losses / NULLIF(e.earned_premium, 0), 4) AS loss_ratio
FROM incurred i JOIN earned e ON i.period = e.period
ORDER BY i.period
"""

REGIONAL_TREND_SQL = f"""
SELECT DATE_TRUNC('month', claim_date) AS period, region,
       SUM(claim_amount) AS total_claims_amount, COUNT(*) AS claim_count
FROM {CATALOG}.gold_claims_ops.claims_fact
GROUP BY 1, 2
ORDER BY 1
"""

SPECIALTY_DENIAL_SQL = f"""
SELECT specialty, COUNT(*) AS total_claims,
       SUM(CASE WHEN claim_status = 'denied' THEN 1 ELSE 0 END) AS denied_claims,
       ROUND(SUM(CASE WHEN claim_status = 'denied' THEN 1 ELSE 0 END) * 1.0 / COUNT(*), 4) AS denial_rate
FROM {CATALOG}.gold_claims_ops.claims_fact
GROUP BY specialty
ORDER BY denial_rate DESC
"""

NETWORK_COST_SQL = f"""
SELECT network_status, COUNT(*) AS claim_count,
       ROUND(AVG(claim_amount), 2) AS avg_claim_amount,
       SUM(claim_amount) AS total_claim_amount
FROM {CATALOG}.gold_claims_ops.claims_fact
GROUP BY network_status
"""

TOP_PROVIDERS_SQL = f"""
SELECT provider_id, specialty, network_status, total_claims, total_billed, denial_rate
FROM {CATALOG}.gold_claims_ops.provider_performance_mart
ORDER BY total_billed DESC
LIMIT 10
"""

RESERVES_SQL = f"""
SELECT valuation_date, SUM(case_reserve) AS total_case_reserve, SUM(ibnr_reserve) AS total_ibnr_reserve
FROM {CATALOG}.gold_finance.reserves_fact
GROUP BY valuation_date
ORDER BY valuation_date
"""

REINSURANCE_SQL = f"""
SELECT treaty_type, COUNT(*) AS claim_count, SUM(ceded_amount) AS total_ceded
FROM {CATALOG}.gold_finance.reinsurance_cession_fact
GROUP BY treaty_type
"""

KPI_SQL = f"""
SELECT
  (SELECT COUNT(*) FROM {CATALOG}.gold_claims_ops.claims_fact) AS total_claims,
  (SELECT SUM(claim_amount) FROM {CATALOG}.gold_claims_ops.claims_fact) AS total_incurred,
  (SELECT SUM(ceded_amount) FROM {CATALOG}.gold_finance.reinsurance_cession_fact) AS total_ceded,
  (SELECT SUM(total_reserve) FROM {CATALOG}.gold_finance.reserves_fact) AS total_reserves
"""


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------
st.title("📊 Healthcare Claims & Loss Performance Overview")
st.markdown(
    "<p style='font-size:17px; color:#8a8f98; margin-top:-10px;'>"
    "A real-time view of claims activity, cost drivers, and financial exposure."
    "</p>",
    unsafe_allow_html=True,
)

kpi = run_query(KPI_SQL).iloc[0]
c1, c2, c3, c4 = st.columns(4)
c1.metric("Total Claims", f"{int(kpi['total_claims']):,}")
c2.metric("Total Incurred", f"${kpi['total_incurred']:,.0f}")
c3.metric("Ceded to Reinsurance", f"${kpi['total_ceded']:,.0f}" if kpi["total_ceded"] else "$0")
c4.metric("Total Reserves Held", f"${kpi['total_reserves']:,.0f}" if kpi["total_reserves"] else "$0")

st.divider()

# --- Loss ratio trend, with computed narrative insight ---
st.subheader("Loss Ratio Trend")
lr = run_query(LOSS_RATIO_SQL)
if not lr.empty:
    avg_ratio = lr["loss_ratio"].mean()
    peak_row = lr.loc[lr["loss_ratio"].idxmax()]
    peak_month = pd.to_datetime(peak_row["period"]).strftime("%B %Y")
    status = "within a healthy range" if avg_ratio < 0.9 else "elevated and worth monitoring"
    st.markdown(
        f"The book is running at an average loss ratio of **{avg_ratio:.2f}**, {status}. "
        f"The highest point was **{peak_row['loss_ratio']:.2f}** in **{peak_month}**, "
        f"driven primarily by a regional cost event (see below)."
    )
    fig = go.Figure()
    fig.add_trace(go.Scatter(x=lr["period"], y=lr["loss_ratio"], mode="lines+markers", name="Loss Ratio",
                              line=dict(color="#4C78A8", width=2.5)))
    fig.add_hline(y=1.0, line_dash="dash", line_color="#E45756",
                  annotation_text="Break-even", annotation_position="bottom right")
    fig.add_vrect(x0="2023-07-01", x1="2023-09-30", fillcolor="#F58518", opacity=0.15, line_width=0)
    fig.update_layout(yaxis_title="Loss Ratio", xaxis_title=None, height=380,
                       plot_bgcolor="white", margin=dict(t=10))
    st.plotly_chart(fig, use_container_width=True)
else:
    st.warning("No data returned. Check that the pipeline has run and Gold tables are populated.")

st.divider()

col_a, col_b = st.columns(2)

with col_a:
    st.subheader("Claims by Region")
    regional = run_query(REGIONAL_TREND_SQL)
    if not regional.empty:
        by_region_total = regional.groupby("region")["total_claims_amount"].sum().sort_values(ascending=False)
        top_region = by_region_total.index[0]
        top_share = by_region_total.iloc[0] / by_region_total.sum()
        st.markdown(
            f"**{top_region.title()}** accounts for the largest share of claims cost "
            f"(**{top_share:.0%}** of total). Watch the visible spike in Q3 2023, "
            f"a regional cost event worth a closer look."
        )
        fig = px.line(regional, x="period", y="total_claims_amount", color="region",
                      labels={"total_claims_amount": "Total Claims ($)", "period": ""})
        fig.update_layout(height=360, margin=dict(t=10), legend_title=None)
        st.plotly_chart(fig, use_container_width=True)

with col_b:
    st.subheader("Denial Rate by Specialty")
    denial = run_query(SPECIALTY_DENIAL_SQL)
    if not denial.empty:
        top_denial = denial.iloc[0]
        st.markdown(
            f"**{top_denial['specialty']}** has the highest denial rate at "
            f"**{top_denial['denial_rate']:.0%}**, a candidate for a documentation "
            f"or prior-authorization review."
        )
        fig = px.bar(denial, x="specialty", y="denial_rate",
                    labels={"denial_rate": "Denial Rate", "specialty": ""},
                    text_auto=".0%", color_discrete_sequence=["#4C78A8"])
        fig.update_layout(yaxis_tickformat=".0%", height=360, margin=dict(t=10), xaxis_tickangle=-30)
        st.plotly_chart(fig, use_container_width=True)

st.divider()

col_c, col_d = st.columns(2)

with col_c:
    st.subheader("In-Network vs. Out-of-Network Cost")
    network = run_query(NETWORK_COST_SQL)
    if not network.empty:
        inn = network[network["network_status"] == "in_network"]["avg_claim_amount"].values
        oon = network[network["network_status"] == "out_of_network"]["avg_claim_amount"].values
        if len(inn) and len(oon):
            pct_more = (oon[0] / inn[0] - 1) * 100
            st.markdown(
                f"Out-of-network claims cost **{pct_more:.0f}% more** on average than in-network care, "
                f"a direct case for steering members toward network providers."
            )
        fig = px.bar(network, x="network_status", y="avg_claim_amount",
                    labels={"avg_claim_amount": "Avg Claim Amount ($)", "network_status": ""},
                    text_auto=".2s", color="network_status",
                    color_discrete_sequence=["#4C78A8", "#E45756"])
        fig.update_layout(showlegend=False, height=340, margin=dict(t=10))
        st.plotly_chart(fig, use_container_width=True)

with col_d:
    st.subheader("Reinsurance Cessions")
    reins = run_query(REINSURANCE_SQL)
    if not reins.empty:
        total_ceded_reins = reins["total_ceded"].sum()
        pct_of_incurred = (total_ceded_reins / kpi["total_incurred"]) * 100 if kpi["total_incurred"] else 0
        st.markdown(
            f"**{pct_of_incurred:.1f}%** of incurred losses have been transferred to reinsurers, "
            f"reducing the company's net retained risk."
        )
        fig = px.pie(reins, names="treaty_type", values="total_ceded", hole=0.45,
                    color_discrete_sequence=["#4C78A8", "#72B7B2"])
        fig.update_layout(height=340, margin=dict(t=10))
        st.plotly_chart(fig, use_container_width=True)

st.divider()

st.subheader("Top Providers by Billed Amount")
providers = run_query(TOP_PROVIDERS_SQL)
if not providers.empty:
    top5_share = providers.head(5)["total_billed"].sum() / providers["total_billed"].sum()
    st.markdown(
        f"The top 5 providers below represent **{top5_share:.0%}** of billed amount among "
        f"the highest-volume providers, a concentrated network worth monitoring for contract leverage."
    )
    st.dataframe(
        providers.rename(columns={
            "provider_id": "Provider ID",
            "specialty": "Specialty",
            "network_status": "Network Status",
            "total_claims": "Total Claims",
            "total_billed": "Total Billed",
            "denial_rate": "Denial Rate",
        }).style.format({"Total Billed": "${:,.0f}", "Denial Rate": "{:.1%}"}),
        use_container_width=True,
    )

st.divider()

st.subheader("Reserve Development")
reserves = run_query(RESERVES_SQL)
if not reserves.empty:
    total_case = reserves["total_case_reserve"].sum()
    total_ibnr = reserves["total_ibnr_reserve"].sum()
    ibnr_share = total_ibnr / (total_case + total_ibnr) if (total_case + total_ibnr) else 0
    st.markdown(
        f"Reserves held for claims Incurred But Not Reported (IBNR) make up "
        f"**{ibnr_share:.0%}** of total reserves, representing losses that have "
        f"occurred but haven't yet been filed as claims."
    )
    fig = go.Figure()
    fig.add_trace(go.Bar(x=reserves["valuation_date"], y=reserves["total_case_reserve"], name="Case Reserve",
                          marker_color="#4C78A8"))
    fig.add_trace(go.Bar(x=reserves["valuation_date"], y=reserves["total_ibnr_reserve"], name="IBNR Reserve",
                          marker_color="#F58518"))
    fig.update_layout(barmode="stack", yaxis_title="Reserve Amount ($)", xaxis_title=None,
                       height=360, margin=dict(t=10))
    st.plotly_chart(fig, use_container_width=True)

st.divider()
st.markdown(
    "<p style='font-size:12px; color:#a0a0a0; text-align:center;'>"
    "Data refreshed automatically from the claims platform pipeline."
    "</p>",
    unsafe_allow_html=True,
)
