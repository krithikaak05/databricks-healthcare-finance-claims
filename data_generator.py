"""
Synthetic data generator for the Databricks Healthcare Claims + Finance
(Reserving / Reinsurance) Platform.

Produces fully synthetic, HIPAA-safe data -- no real PHI -- calibrated to
produce a realistic, dashboard-worthy story rather than pure random noise.

Run with:
    pip install faker numpy pandas pyarrow --break-system-packages
    python data_generator.py --out ./synthetic_data --scale 1.0

`--scale` multiplies row counts (1.0 = full size described in README, ~30M+ rows
across all tables). Use a small scale (e.g. 0.01) for local dev/testing.

DELIBERATE STORY SIGNALS BUILT IN (so a dashboard has something real to say):
  1. Regional cost spike: the Southeast region has an elevated claim
     frequency + severity in Q3 2023 (a "flu season" story) -- shows up as
     a visible spike in any claims-over-time-by-region chart.
  2. Specialty denial-rate difference: Behavioral Health claims are denied
     roughly 2x as often as other specialties -- a realistic, defensible
     "which specialty needs a coding/documentation review" insight.
  3. Network status cost difference: out-of-network claims run
     meaningfully more expensive than in-network -- the standard
     "steering members in-network saves money" insurance narrative.
  4. Loss ratio calibrated to land around 0.65-0.85 in aggregate (realistic
     for a health insurer), by ensuring EVERY member with claims also has a
     matching premium history -- no artificial member-subset mismatch
     between claims and premiums.

Output: one Parquet file per table, ready to land in a cloud storage landing
zone that Auto Loader (notebooks/02_bronze_ingestion.py) reads from.
"""

import argparse
import os
import uuid
from datetime import date, timedelta

import numpy as np
import pandas as pd
from faker import Faker

fake = Faker()
Faker.seed(42)
np.random.seed(42)


def sanitize_timestamps(df):
    """Downcast nanosecond-precision datetime64 columns to microsecond
    precision -- Spark/Databricks parquet readers reject ns precision with
    PARQUET_TYPE_ILLEGAL (Spark only supports up to microsecond precision).
    Applied to every table before writing, as a safe no-op for tables that
    have no datetime64 columns at all."""
    for col in df.columns:
        if pd.api.types.is_datetime64_any_dtype(df[col]):
            df[col] = df[col].astype("datetime64[us]")
    return df


DIAGNOSIS_CODES = [
    "E11.9", "I10", "J45.909", "M54.5", "F41.1", "K21.9", "N39.0",
    "R07.9", "M17.9", "G43.909", "E78.5", "J06.9", "L03.90", "H35.30",
]
CLAIM_STATUSES = ["submitted", "in_review", "adjudicated", "paid", "denied", "appealed"]
DENIAL_REASONS = [
    "Prior authorization not obtained",
    "Service not covered under plan",
    "Duplicate claim submission",
    "Missing clinical documentation",
    "Provider out of network",
    "Timely filing limit exceeded",
]
PLAN_TYPES = ["HMO", "PPO", "EPO", "HDHP", "POS"]
SPECIALTIES = [
    "Primary Care", "Cardiology", "Orthopedics", "Behavioral Health",
    "Dermatology", "Radiology", "Oncology", "Endocrinology", "Neurology",
]
REGIONS = ["northeast", "southeast", "midwest", "west", "southwest"]
TREATY_TYPES = ["excess_of_loss", "quota_share"]

# Story signal #1: regional cost spike window (Southeast, "flu season" Q3 2023)
SPIKE_REGION = "southeast"
SPIKE_START = date(2023, 7, 1)
SPIKE_END = date(2023, 9, 30)
SPIKE_SEVERITY_MULTIPLIER = 1.8   # claims cost ~80% more during the spike
SPIKE_FREQUENCY_MULTIPLIER = 2.2  # ~2.2x as many claims land in this window

# Story signal #2: specialty denial-rate difference
HIGH_DENIAL_SPECIALTY = "Behavioral Health"
HIGH_DENIAL_RATE = 0.22     # vs. ~0.10 baseline for everything else
BASE_DENIAL_RATE = 0.10

# Story signal #3: out-of-network cost multiplier
OON_COST_MULTIPLIER = 1.6


def gen_providers(n):
    rows = []
    # Round-robin specialty assignment (shuffled) instead of pure random
    # choice -- guarantees every specialty gets a roughly even share of
    # providers regardless of scale, so a specialty-level signal (like the
    # Behavioral Health denial rate below) has a reliable sample size to
    # show up in, rather than depending on random luck. At small --scale
    # values with few providers, pure np.random.choice can easily leave a
    # specialty with 0-1 providers by chance, which silently kills any
    # signal tied to that specialty.
    specialty_cycle = (SPECIALTIES * ((n // len(SPECIALTIES)) + 1))[:n]
    np.random.shuffle(specialty_cycle)

    for i in range(n):
        rows.append({
            "provider_id": f"PRV{i:07d}",
            "provider_name": fake.company() + " Medical Group",
            "specialty": specialty_cycle[i],
            "region": np.random.choice(REGIONS),
            "network_status": np.random.choice(["in_network", "out_of_network"], p=[0.85, 0.15]),
            "npi": fake.numerify("##########"),
        })
    return pd.DataFrame(rows)


def gen_members(n):
    rows = []
    start = date(2018, 1, 1)
    for i in range(n):
        member_id = f"MBR{i:07d}"
        # simulate 1-3 plan-change events per member for SCD2 downstream logic
        n_events = np.random.choice([1, 2, 3], p=[0.7, 0.2, 0.1])
        event_date = start + timedelta(days=int(np.random.randint(0, 1500)))
        for _ in range(n_events):
            rows.append({
                "member_id": member_id,
                "plan_type": np.random.choice(PLAN_TYPES),
                "address": fake.address().replace("\n", ", "),
                "region": np.random.choice(REGIONS),
                "effective_date": event_date,
                "birth_date": fake.date_of_birth(minimum_age=1, maximum_age=95),
            })
            event_date = event_date + timedelta(days=int(np.random.randint(90, 400)))
    return pd.DataFrame(rows)


def gen_claims(n, provider_ids, member_ids, providers_df):
    # deliberate skew: 80% of claims from 20% of providers
    n_hot_providers = max(1, int(len(provider_ids) * 0.2))
    hot_providers = np.random.choice(provider_ids, n_hot_providers, replace=False)

    start = date(2022, 1, 1)
    end = date(2026, 6, 1)
    days_range = (end - start).days

    provider_lookup = providers_df.set_index("provider_id")[["region", "network_status", "specialty"]]

    rows = []
    base_n = int(n / (SPIKE_FREQUENCY_MULTIPLIER ** 0.15))  # mild correction so final count ~= n

    for _ in range(base_n):
        provider_id = np.random.choice(hot_providers) if np.random.random() < 0.8 else np.random.choice(provider_ids)
        provider_region = provider_lookup.loc[provider_id, "region"]
        network_status = provider_lookup.loc[provider_id, "network_status"]
        specialty = provider_lookup.loc[provider_id, "specialty"]

        claim_date = start + timedelta(days=int(np.random.randint(0, days_range)))

        in_spike_window = (
            provider_region == SPIKE_REGION and SPIKE_START <= claim_date <= SPIKE_END
        )

        base_amount = np.random.lognormal(mean=6.2, sigma=0.9)
        if in_spike_window:
            base_amount *= SPIKE_SEVERITY_MULTIPLIER
        if network_status == "out_of_network":
            base_amount *= OON_COST_MULTIPLIER

        denial_rate = HIGH_DENIAL_RATE if specialty == HIGH_DENIAL_SPECIALTY else BASE_DENIAL_RATE
        other_statuses = ["submitted", "in_review", "adjudicated", "paid", "appealed"]
        other_probs = [0.05, 0.10, 0.15, 0.60, 0.10]
        other_probs = [p * (1 - denial_rate) for p in other_probs]
        status = np.random.choice(other_statuses + ["denied"], p=other_probs + [denial_rate])

        rows.append({
            "claim_id": str(uuid.uuid4()),
            "member_id": np.random.choice(member_ids),
            "provider_id": provider_id,
            "claim_date": claim_date,
            "claim_amount": round(float(base_amount), 2),
            "claim_status": status,
            "diagnosis_code": np.random.choice(DIAGNOSIS_CODES),
        })

        # Extra claims during the spike window for the affected region --
        # this is what makes the spike show up as a FREQUENCY jump too, not
        # just a severity jump, which is more realistic for an outbreak
        # story (more people seek care, and each visit costs somewhat more).
        if in_spike_window and np.random.random() < (SPIKE_FREQUENCY_MULTIPLIER - 1):
            extra_amount = np.random.lognormal(mean=6.2, sigma=0.9) * SPIKE_SEVERITY_MULTIPLIER
            if network_status == "out_of_network":
                extra_amount *= OON_COST_MULTIPLIER
            rows.append({
                "claim_id": str(uuid.uuid4()),
                "member_id": np.random.choice(member_ids),
                "provider_id": provider_id,
                "claim_date": claim_date + timedelta(days=int(np.random.randint(0, 14))),
                "claim_amount": round(float(extra_amount), 2),
                "claim_status": np.random.choice(other_statuses + ["denied"], p=other_probs + [denial_rate]),
                "diagnosis_code": np.random.choice(DIAGNOSIS_CODES),
            })

    return pd.DataFrame(rows)


def gen_claim_notes(claims_df):
    """Notes now reference the claim's actual specialty/denial context so
    ai_query() summaries are coherent instead of pure gibberish -- a real
    dashboard/demo audience (or an interviewer) will read a few of these,
    and grammatically-random Faker sentences undercut the story."""
    rows = []
    for _, c in claims_df.iterrows():
        if c["claim_status"] == "denied":
            reason = np.random.choice(DENIAL_REASONS)
            text = (f"Claim denied. Reason: {reason}. Diagnosis code {c['diagnosis_code']} "
                    f"reviewed against plan coverage rules; adjuster recommends member appeal "
                    f"if additional documentation becomes available.")
        elif c["claim_status"] == "appealed":
            text = (f"Appeal received for previously denied claim (diagnosis {c['diagnosis_code']}). "
                    f"Adjuster re-reviewing supporting documentation submitted by provider.")
        else:
            text = (f"Claim processed under standard review for diagnosis code {c['diagnosis_code']}. "
                    f"No documentation issues identified; routed for standard adjudication.")
        rows.append({"claim_id": c["claim_id"], "note_text": text, "note_date": c["claim_date"]})
    return pd.DataFrame(rows)


def gen_claim_status_updates(claim_ids, avg_updates_per_claim=1.5):
    rows = []
    for cid in claim_ids:
        n_updates = np.random.poisson(avg_updates_per_claim) + 1
        for _ in range(n_updates):
            rows.append({
                "claim_id": cid,
                "status": np.random.choice(CLAIM_STATUSES),
                "status_timestamp": fake.date_time_between(start_date="-3y"),
            })
    return pd.DataFrame(rows)


def gen_reinsurance_treaties(n=120):
    rows = []
    start = date(2020, 1, 1)
    for i in range(n):
        ttype = np.random.choice(TREATY_TYPES)
        eff = start + timedelta(days=int(np.random.randint(0, 1800)))
        rows.append({
            "treaty_id": f"TRTY{i:04d}",
            "treaty_type": ttype,
            "attachment_point": float(np.random.choice([50000, 100000, 250000])) if ttype == "excess_of_loss" else None,
            "treaty_limit": float(np.random.choice([500000, 1000000, 2000000])) if ttype == "excess_of_loss" else None,
            "cession_pct": round(np.random.uniform(0.1, 0.5), 2) if ttype == "quota_share" else None,
            "effective_date": eff,
            "expiry_date": eff + timedelta(days=365),
            "reinsurer_name": fake.company() + " Re",
        })
    return pd.DataFrame(rows)


def gen_reserves(claims_df, n_valuations=3):
    rows = []
    open_claims = claims_df[claims_df["claim_status"].isin(
        ["submitted", "in_review", "adjudicated", "appealed"]
    )]
    for _, c in open_claims.iterrows():
        for v in range(n_valuations):
            val_date = pd.to_datetime(c["claim_date"]) + pd.DateOffset(months=v + 1)
            case_reserve = round(float(c["claim_amount"]) * np.random.uniform(0.4, 1.1), 2)
            rows.append({
                "claim_id": c["claim_id"],
                "valuation_date": val_date.date(),
                "case_reserve": case_reserve,
                "ibnr_reserve": round(case_reserve * np.random.uniform(0.05, 0.25), 2),
            })
    return pd.DataFrame(rows)


def gen_premium_transactions(member_ids, n_months=54, target_loss_ratio=0.72, avg_claim_total_per_member=None):
    """Every member passed in gets a full premium history -- no artificial
    subsetting against the claims population. Premium level is calibrated
    against the actual average per-member claims total so the resulting
    loss ratio lands close to target_loss_ratio in aggregate, rather than
    being an arbitrary uniform(250,900) guess."""
    rows = []
    start = date(2022, 1, 1)

    if avg_claim_total_per_member is not None and avg_claim_total_per_member > 0:
        implied_total_premium = avg_claim_total_per_member / target_loss_ratio
        implied_monthly_base = max(150.0, implied_total_premium / n_months)
    else:
        implied_monthly_base = 575.0

    for mid in member_ids:
        base_premium = round(implied_monthly_base * np.random.uniform(0.85, 1.15), 2)
        for m in range(n_months):
            period = start + pd.DateOffset(months=m)
            rows.append({
                "member_id": mid,
                "period_date": period.date(),
                "premium_amount": round(base_premium * np.random.uniform(0.98, 1.03), 2),
                "payment_status": np.random.choice(["paid", "late", "unpaid"], p=[0.9, 0.07, 0.03]),
            })
    return pd.DataFrame(rows)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default="./synthetic_data")
    ap.add_argument("--scale", type=float, default=1.0,
                     help="Multiplier on base row counts (1.0 = ~30M rows total)")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    n_providers = max(10, int(25_000 * args.scale))
    n_members_base = max(10, int(500_000 * args.scale))
    n_claims = max(10, int(8_000_000 * args.scale))

    print(f"Generating providers (~{n_providers})...")
    providers = gen_providers(n_providers)
    providers = sanitize_timestamps(providers)
    providers.to_parquet(f"{args.out}/providers.parquet", index=False)

    print(f"Generating members (~{n_members_base} base members, with plan-change history)...")
    members = gen_members(n_members_base)
    members = sanitize_timestamps(members)
    members.to_parquet(f"{args.out}/members.parquet", index=False)
    member_ids = members["member_id"].unique()

    print(f"Generating claims (~{n_claims}, with regional spike + specialty denial + network cost signals)...")
    claims = gen_claims(n_claims, providers["provider_id"].values, member_ids, providers)
    claims = sanitize_timestamps(claims)
    claims.to_parquet(f"{args.out}/claims.parquet", index=False)
    print(f"  -> actual claims generated: {len(claims)}")

    print("Generating claim notes (context-aware, tied to actual claim status/diagnosis)...")
    sample_n = min(len(claims), max(10, int(1_000_000 * args.scale)))
    notes = gen_claim_notes(claims.sample(sample_n, random_state=3))
    notes = sanitize_timestamps(notes)
    notes.to_parquet(f"{args.out}/claim_notes.parquet", index=False)

    print("Generating claim status updates (CDC source)...")
    status_updates = gen_claim_status_updates(claims["claim_id"].values[: min(len(claims), max(10, int(4_000_000 * args.scale)))])
    status_updates = sanitize_timestamps(status_updates)
    status_updates.to_parquet(f"{args.out}/claim_status_updates.parquet", index=False)

    print("Generating reinsurance treaties...")
    treaties = gen_reinsurance_treaties(max(5, int(120 * args.scale)))
    treaties = sanitize_timestamps(treaties)
    treaties.to_parquet(f"{args.out}/reinsurance_treaties.parquet", index=False)

    print("Generating reserves (finance module)...")
    reserves = gen_reserves(claims.sample(min(len(claims), max(10, int(2_000_000 * args.scale))), random_state=1))
    reserves = sanitize_timestamps(reserves)
    reserves.to_parquet(f"{args.out}/reserves.parquet", index=False)

    print("Calibrating premium levels against actual claims experience...")
    claims_per_member = claims.groupby("member_id")["claim_amount"].sum()
    avg_claim_total_per_member = claims_per_member.mean() if len(claims_per_member) > 0 else None
    n_months = max(1, int((date(2026, 6, 1) - date(2022, 1, 1)).days / 30))

    print(f"Generating premium transactions for ALL {len(member_ids)} members "
          f"(no subsetting -- every member with claims has a matching premium history)...")
    premiums = gen_premium_transactions(
        member_ids,
        n_months=n_months,
        target_loss_ratio=0.72,
        avg_claim_total_per_member=avg_claim_total_per_member,
    )
    premiums = sanitize_timestamps(premiums)
    premiums.to_parquet(f"{args.out}/premium_transactions.parquet", index=False)

    print(f"\nDone. Files written to {args.out}/")
    print("Upload these to your cloud landing zone (S3/ADLS/GCS) for Auto Loader to pick up.")
    print("\nStory signals baked into this data:")
    print(f"  1. Regional spike: {SPIKE_REGION} region, {SPIKE_START} to {SPIKE_END} "
          f"(~{SPIKE_SEVERITY_MULTIPLIER}x severity, ~{SPIKE_FREQUENCY_MULTIPLIER}x frequency)")
    print(f"  2. {HIGH_DENIAL_SPECIALTY} denial rate ~{HIGH_DENIAL_RATE:.0%} vs ~{BASE_DENIAL_RATE:.0%} baseline")
    print(f"  3. Out-of-network claims ~{OON_COST_MULTIPLIER}x more expensive than in-network")
    print(f"  4. Premiums calibrated for an aggregate loss ratio near 0.72 (realistic range)")


if __name__ == "__main__":
    main()
