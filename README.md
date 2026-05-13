# civic-pulse

A small, hands-on **dbt + Snowflake learning project** built around real
Memphis crime data. The repository doubles as a **tutorial**: every file
is accompanied by a chapter in `docs/` that explains what it does, why
it's shaped that way, and what alternatives were rejected.

You'll learn dbt fundamentals against a local DuckDB warehouse first
(no Snowflake credentials needed for 7 of the 8 lessons), then port the
same project to Snowflake as a capstone. The point isn't a production
pipeline — it's the smallest project that exercises the core dbt
concepts cleanly.

---

## How to use this repo

1. Read the lesson chapter (`docs/lesson-NN-*.md`).
2. Look at the files it added or changed (`git show` for that lesson's commit).
3. Run the commands at the end of each chapter against your local copy.
4. Try the "Try it yourself" extensions if you want to actively practice.

Lessons are designed to be ~2-3 hours each, including the run-and-experiment
phase. The project assumes solid Python + SQL skills — we skip language
basics and focus on dbt/Snowflake mental models.

---

## Curriculum

| # | Chapter | Concepts | Status |
|---|---------|----------|--------|
| 1 | [Setup & first run](docs/lesson-01-setup-and-first-run.md) | dbt project anatomy, profiles, adapters | ✓ |
| 2 | [Ingest & sources](docs/lesson-02-ingest-and-sources.md) | Python EL, Socrata API, `source()` | ✓ |
| 3 | First staging model | `ref()`, view vs table materialization | — |
| 4 | Tests & docs | generic + singular tests, `dbt docs` | — |
| 5 | Marts & star schema | dimensional modeling, seeds, surrogate keys | — |
| 6 | Jinja, macros, packages | `dbt deps`, custom macros, `dbt_utils` | — |
| 7 | Incremental & snapshots | `is_incremental()`, SCD2 history | — |
| 8 | Port to Snowflake | adapter swap, COPY INTO, dialect differences | — |

The [`docs/decisions.md`](docs/decisions.md) file is a running log of
every non-trivial design choice — useful as a flat reference when
you've finished the lessons and want to remember *why* something is
the way it is.

---

## Quickstart (after Lesson 1)

```bash
# Clone and enter
git clone <this-repo> && cd civic-pulse

# Python env + dbt
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt

# Configure your dbt profile (edit the path inside)
mkdir -p ~/.dbt
cp profiles.yml.example ~/.dbt/profiles.yml
# Then open ~/.dbt/profiles.yml and replace the duckdb `path:` placeholder.

# Verify
dbt debug      # should print "All checks passed!"
dbt parse      # should succeed even with zero models
```

---

## Tech stack

- **dbt-core** + **dbt-duckdb** (Lessons 1-7), **dbt-snowflake** (Lesson 8)
- **DuckDB** as the local warehouse — single-file, zero-setup, fast
- **Python** (`requests`, `python-dotenv`) for the one-shot ingest script
- **Snowflake** trial account for Lesson 8 ($400 of free credit, plenty)

No orchestrator, no CI, no dbt Cloud. The dbt CLI from your terminal
is enough for the entire project.

## Data source

[Memphis Police Department incident data](https://data.memphistn.gov)
via the Socrata Open Data API. Public, well-documented, and just
messy enough to give the staging layer real work to do.
