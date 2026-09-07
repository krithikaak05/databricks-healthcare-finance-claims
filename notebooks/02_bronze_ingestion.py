# Databricks notebook source
# 02_bronze_ingestion.py
#
# Auto Loader ingestion into Bronze. This is the direct replacement for
# Snowflake's external stage + COPY INTO / Snowpipe.
#
# Why Auto Loader instead of a plain batch read?
# It incrementally and efficiently discovers new files as they land in cloud
# storage (via file notifications or directory listing), tracks what it has
# already processed in its own checkpoint, and scales to millions of files
# without you hand-managing a "what have I already loaded" table.
#
# Why land as a loosely-typed payload before typing anything downstream?
# For JSON sources this would mean landing as a single VARIANT/MAP-style
# payload column. This project's source is parquet, so Auto Loader
# preserves the original flat column names directly -- Silver still owns
# all type-casting and cleansing, so upstream schema drift is caught there.

# COMMAND ----------

# Defaults point at a Unity Catalog Volume (see 01_setup_catalog_schemas.sql)
# rather than an external S3/ADLS/GCS bucket -- this works on Free Edition,
# which does not permit wiring Auto Loader to custom external storage.
# If re-running this notebook after clearing Bronze, change the checkpoint
# suffix (e.g. _v2, _v3) to force Auto Loader to re-read every file --
# otherwise it treats already-seen filenames as already-processed even if
# the target Bronze table was truncated.
dbutils.widgets.text("landing_path", "/Volumes/healthcare_claims/bronze/landing_zone/raw", "Landing zone path")
dbutils.widgets.text("checkpoint_path", "/Volumes/healthcare_claims/bronze/landing_zone/_checkpoints_v2", "Checkpoint root")

landing_path = dbutils.widgets.get("landing_path")
checkpoint_root = dbutils.widgets.get("checkpoint_path")

CATALOG = "healthcare_claims"
BRONZE = f"{CATALOG}.bronze"

spark.sql(f"USE CATALOG {CATALOG}")

# COMMAND ----------

from pyspark.sql import functions as F


def autoload_to_bronze(source_subdir: str, bronze_table: str, file_format: str = "parquet"):
    checkpoint = f"{checkpoint_root}/{bronze_table}/"

    df = (
        spark.readStream.format("cloudFiles")
        .option("cloudFiles.format", file_format)
        .option("cloudFiles.schemaLocation", checkpoint + "schema/")
        .option("cloudFiles.inferColumnTypes", "true")
        .option("cloudFiles.rescuedDataColumn", "_rescued_data")
        .load(f"{landing_path}/{source_subdir}/")
        .withColumn("_loaded_at", F.current_timestamp())
    )

    (
        df.writeStream.format("delta")
        .option("checkpointLocation", checkpoint)
        .option("mergeSchema", "true")
        .trigger(availableNow=True)
        .toTable(f"{BRONZE}.{bronze_table}")
    )

# COMMAND ----------

# Slow-moving dimensions
autoload_to_bronze("members", "members_raw")
autoload_to_bronze("providers", "providers_raw")
autoload_to_bronze("reinsurance_treaties", "reinsurance_treaties_raw")
autoload_to_bronze("premium_transactions", "premium_transactions_raw")

# COMMAND ----------

# Fact / high-volume sources
autoload_to_bronze("claims", "claims_raw")
autoload_to_bronze("claim_notes", "claim_notes_raw")
autoload_to_bronze("reserves", "reserves_raw")

# COMMAND ----------

# Claim status updates: the CDC-ish, continuously-arriving source. In
# production, schedule this on a short-interval Job rather than availableNow,
# to mimic near-real-time arrival.
autoload_to_bronze("status_updates", "claim_status_updates_raw")

# COMMAND ----------

print("Bronze ingestion complete for this run.")
for t in ["members_raw", "providers_raw", "reinsurance_treaties_raw",
          "premium_transactions_raw", "claims_raw", "claim_notes_raw",
          "reserves_raw", "claim_status_updates_raw"]:
    cnt = spark.table(f"{BRONZE}.{t}").count()
    print(f"  {BRONZE}.{t}: {cnt:,} rows")
