# Databricks notebook source
# 07b_finance_reserving_pyspark.py
#
# IBNR (Incurred But Not Reported) triangle-style projection.
#
# Why PySpark instead of pure SQL here?
# The reporting-lag cohort math (grouping claims by service month, tracking
# how many arrive in each subsequent reporting month, projecting forward for
# the tail) involves rule cascades and windowed cohort logic that's awkward
# as a single SQL statement but natural as DataFrame operations -- the same
# justification the original Snowflake project gave for Snowpark.
#
# IMPORTANT: this is an illustrative, simplified chain-ladder-style
# projection for portfolio/demo purposes -- not a filing-grade actuarial
# method. A production IBNR estimate would be reviewed and signed off by a
# credentialed actuary using a proper loss development methodology.

# COMMAND ----------

from pyspark.sql import functions as F

CATALOG = "healthcare_claims"
spark.sql(f"USE CATALOG {CATALOG}")

claims = spark.table(f"{CATALOG}.gold_claims_ops.claims_fact")
status = spark.table(f"{CATALOG}.silver.claim_status_current")

# COMMAND ----------

lagged = (
    claims.join(status, "claim_id", "left")
    .withColumn("service_month", F.trunc("claim_date", "month"))
)

cohort_counts = (
    claims.withColumn("service_month", F.trunc("claim_date", "month"))
    .groupBy("service_month")
    .agg(F.count("*").alias("ultimate_claim_count_estimate"))
)

reported_counts = (
    lagged.filter(F.col("status").isin("adjudicated", "paid", "denied"))
    .withColumn("service_month", F.trunc("claim_date", "month"))
    .groupBy("service_month")
    .agg(F.count("*").alias("reported_claim_count"))
)

development = (
    cohort_counts.join(reported_counts, "service_month", "left")
    .fillna(0, subset=["reported_claim_count"])
    .withColumn(
        "reporting_completeness_pct",
        F.round(F.col("reported_claim_count") / F.col("ultimate_claim_count_estimate"), 4),
    )
    .withColumn(
        "estimated_unreported_claims",
        F.col("ultimate_claim_count_estimate") - F.col("reported_claim_count"),
    )
)

# COMMAND ----------

avg_severity = claims.agg(F.avg("claim_amount").alias("avg_severity")).collect()[0]["avg_severity"]

ibnr_by_month = development.withColumn(
    "ibnr_dollar_estimate",
    F.round(F.col("estimated_unreported_claims") * F.lit(avg_severity), 2),
)

display(ibnr_by_month.orderBy("service_month"))

# COMMAND ----------

(
    ibnr_by_month.write.mode("overwrite")
    .option("mergeSchema", "true")
    .saveAsTable(f"{CATALOG}.gold_finance.ibnr_by_service_month")
)

print(f"Wrote {ibnr_by_month.count():,} monthly IBNR cohort rows to {CATALOG}.gold_finance.ibnr_by_service_month")
