"""
Ingest Memphis Police Department incident data into local DuckDB.

This script owns EXTRACT and LOAD. dbt owns TRANSFORM. We keep the
boundary clean so each tool does what it's best at:

  - requests + DuckDB's native JSON ingestion is the right hammer for
    "fetch JSON from an HTTP API and put it in a table". It's <100
    lines of Python and easy to debug.
  - dbt would have to express the same logic as either a Python model
    (heavy, adapter-specific) or convoluted Jinja around an extension
    function. Neither is a good fit.

Idempotency: this script DROPs and REPLACEs raw.incidents on every
run. Lesson 7 introduces *incremental* ingestion when we cover dbt's
incremental materialization.

Usage:
    python data-engineering/ingest/load_memphis_crime.py

Configuration (via .env or environment):
    SOCRATA_DATASET_ID    The 4-by-4 dataset id from data.memphistn.gov,
                          e.g. "abcd-1234". See docs/lesson-02 for
                          how to locate the current id.
    SOCRATA_APP_TOKEN     Optional. Without it, Socrata throttles
                          anonymous requests. Free token at
                          https://dev.socrata.com.
    DUCKDB_PATH           Optional absolute path. Defaults to
                          civic_pulse.duckdb at the repo root, which
                          matches the path in profiles.yml.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

import duckdb
import requests
from dotenv import load_dotenv


SOCRATA_HOST = "https://data.memphistn.gov"
RAW_SCHEMA = "raw"
RAW_TABLE = "incidents"

# Socrata's documented per-request cap is 50_000. Lower this if you
# hit timeouts on a slow connection; raise it only if Socrata bumps
# the limit (they haven't in years).
PAGE_SIZE = 50_000

REPO_ROOT = Path(__file__).resolve().parents[2]
DEFAULT_DUCKDB_PATH = REPO_ROOT / "civic_pulse.duckdb"


def fetch_all_rows(dataset_id: str, app_token: str | None) -> list[dict]:
    """Page through the Socrata SODA endpoint until the dataset is drained."""
    url = f"{SOCRATA_HOST}/resource/{dataset_id}.json"
    headers = {"X-App-Token": app_token} if app_token else {}
    rows: list[dict] = []
    offset = 0

    while True:
        params = {"$limit": PAGE_SIZE, "$offset": offset}
        resp = requests.get(url, params=params, headers=headers, timeout=60)
        resp.raise_for_status()
        page = resp.json()
        if not page:
            break

        rows.extend(page)
        print(
            f"  fetched page (offset={offset:>7}, "
            f"rows={len(page):>6}, total={len(rows):,})"
        )

        # A partial page is always the last page — Socrata only returns
        # fewer rows than the requested limit when there's nothing left.
        if len(page) < PAGE_SIZE:
            break
        offset += PAGE_SIZE

    return rows


def load_to_duckdb(rows: list[dict], db_path: Path) -> int:
    """Replace raw.incidents with the freshly-fetched rows. Returns the row count."""
    if not rows:
        print("No rows returned; leaving any existing table untouched.")
        return 0

    # Write the rows to a newline-delimited JSON file in /tmp and let
    # DuckDB ingest it natively via read_json_auto. This:
    #   - avoids depending on pandas or pyarrow for the in-memory pivot
    #   - lets DuckDB infer column names and types from the JSON
    #   - demonstrates a real-world useful pattern (DuckDB's JSON reader
    #     is one of its quietly excellent features)
    with tempfile.NamedTemporaryFile(
        mode="w", suffix=".jsonl", delete=False, encoding="utf-8"
    ) as tmp:
        for row in rows:
            tmp.write(json.dumps(row) + "\n")
        tmp_path = tmp.name

    try:
        con = duckdb.connect(str(db_path))
        try:
            con.execute(f"CREATE SCHEMA IF NOT EXISTS {RAW_SCHEMA}")

            # CREATE OR REPLACE is the idempotency lever: every run
            # produces a fresh, complete table. Appropriate for
            # full-refresh loads of small/medium datasets. Lesson 7
            # covers the incremental alternative for large datasets
            # where re-loading everything is wasteful.
            con.execute(
                f"CREATE OR REPLACE TABLE {RAW_SCHEMA}.{RAW_TABLE} AS "
                f"SELECT * FROM read_json_auto(?, format='newline_delimited')",
                [tmp_path],
            )

            (count,) = con.execute(
                f"SELECT count(*) FROM {RAW_SCHEMA}.{RAW_TABLE}"
            ).fetchone()
            return count
        finally:
            con.close()
    finally:
        Path(tmp_path).unlink(missing_ok=True)


def main() -> int:
    load_dotenv()  # reads .env from CWD if present; harmless if not

    dataset_id = os.environ.get("SOCRATA_DATASET_ID")
    if not dataset_id:
        print(
            "ERROR: SOCRATA_DATASET_ID is not set.\n\n"
            "Find the current Memphis incidents dataset 4-by-4 id at\n"
            "https://data.memphistn.gov (see docs/lesson-02-ingest-and-sources.md),\n"
            "then add it to .env:\n\n"
            "    SOCRATA_DATASET_ID=xxxx-xxxx\n",
            file=sys.stderr,
        )
        return 1

    app_token = os.environ.get("SOCRATA_APP_TOKEN")
    db_path = Path(os.environ.get("DUCKDB_PATH") or DEFAULT_DUCKDB_PATH)

    print(f"Fetching Memphis incidents from dataset '{dataset_id}'...")
    if not app_token:
        print("  (no SOCRATA_APP_TOKEN set; may hit anonymous rate limits)")
    rows = fetch_all_rows(dataset_id, app_token)
    print(f"Fetch complete: {len(rows):,} rows.")

    count = load_to_duckdb(rows, db_path)
    print(f"Loaded {count:,} rows into {RAW_SCHEMA}.{RAW_TABLE} at {db_path}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
