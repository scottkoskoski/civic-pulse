# Design Decisions Log

A running, one-line-per-decision summary of choices made during the
tutorial. The full reasoning lives in the lesson chapters; this file
exists so you can scan the whole project's rationale without re-reading
8 chapters.

Format: `## Lesson N — Topic` followed by bullets, each linking back
to the source-of-truth chapter for the long explanation.

---

## Lesson 1 — Setup & first run

- **Warehouse for Lessons 1-7: DuckDB, not Snowflake.** Zero credentials,
  zero credits, instant local feedback. We port to Snowflake in Lesson 8
  to demonstrate that dbt's value is *adapter-agnostic*. See
  [lesson-01](lesson-01-setup-and-first-run.md#why-duckdb-first).
- **`profiles.yml` lives in `~/.dbt/`, not in the repo.** Production
  profiles end up holding real credentials; keeping them outside the
  working tree means a slip of `git add` cannot commit them. We ship a
  `profiles.yml.example` template instead, and `.gitignore` excludes
  any `profiles.yml` accidentally created at the repo root.
- **Loose version pins (`>=1.8,<2.0`).** Tight pins like `==1.8.3`
  block patch releases for no real benefit on a learning project.
  Upper bound on the major prevents an unattended breaking change.
- **`dbt-snowflake` is commented out in `requirements.txt`.** Installing
  it in Lesson 1 would try to compile Snowflake adapter dependencies
  that we don't need yet. Uncommented in Lesson 8.
- **Per-folder schemas via `dbt_project.yml`.** `staging`, `marts`,
  `snapshots` as separate schemas makes intent obvious when querying
  DuckDB ad-hoc and mirrors how a Snowflake deployment would be
  organized.
- **Default materializations: `view` for staging, `table` for marts.**
  Views are zero-storage and always-fresh, perfect for cheap rename/cast
  layers. Marts back BI queries, so a physical table avoids re-running
  the staging SQL on every dashboard click.
- **Skip `dbt init` scaffolding; commit a hand-shaped project instead.**
  `dbt init` produces a sample `my_first_dbt_model.sql` that we'd
  immediately delete. Starting clean keeps the diff per lesson honest.
- **`packages.yml` exists from day one, but empty.** Signals to readers
  that we will add packages later (Lesson 6). One less file to introduce
  mid-tutorial.

## Lesson 2 — Ingest & sources

- **Extract + load lives in Python, not dbt.** dbt is the T in ELT.
  Mixing API extraction with transformation conflates failure modes
  (a 429 from Socrata shouldn't fail `dbt run`). See
  [lesson-02](lesson-02-ingest-and-sources.md#1-data-engineeringingestload_memphis_crimepy).
- **Loader writes via a temp JSONL file + DuckDB's `read_json_auto`.**
  Avoids depending on pandas/pyarrow, handles Socrata's sparse JSON
  cleanly, and demonstrates a useful DuckDB feature. Considered and
  rejected: per-row INSERTs (requires pre-knowing the schema), pandas
  bulk-load (extra dependency).
- **`CREATE OR REPLACE TABLE` on every load.** Idempotent and trivially
  correct for small datasets. Lesson 7's incremental materialization
  handles the scale-up case.
- **Dataset id is read from `SOCRATA_DATASET_ID`, never hardcoded.**
  Memphis occasionally republishes datasets under new ids; an env
  var forces a one-time setup choice instead of silent rot.
- **Source name is `memphis`, table is `incidents`.** Short, stable,
  and leaves the namespace open for other Memphis datasets later
  (311, permits) without rename pain.
- **`_sources.yml` lives in `models/staging/`.** Sources sit
  conceptually upstream of staging, so co-locating the YAML with
  the consumers makes lineage navigation obvious.
- **`.env.example` is committed; `.env` is gitignored.** Standard
  pattern for documenting required environment variables without
  leaking secrets.

## Lesson 3 — Staging & materializations

- **CTE-first model structure: `source` → `renamed` → final select.**
  Project-wide convention. Every model has the same top-to-bottom
  shape so reading unfamiliar models is fast. See
  [lesson-03](lesson-03-staging-and-materializations.md#the-cte-first-pattern).
- **Inline `{{ config(materialized='view') }}` even though the
  folder default says the same thing.** Trades redundancy for
  locality — reading a single .sql file tells you the materialization.
  The inline config travels with the file if it's ever moved.
- **`try_cast`, not `cast`.** Type-coercion failures become NULLs
  instead of build failures. Quality issues surface as test
  failures (Lesson 4), not pipeline crashes.
- **Lat/lng = 0 collapses to NULL.** Sentinel-to-NULL is a
  staging-layer concern; doing it once here means downstream models
  never have to remember the sentinel.
- **`lower(trim(...))` + `nullif(..., '')` for string normalization.**
  Canonicalizes casing, strips whitespace, and forces empty-string
  results to NULL so downstream `is not null` filters work
  consistently.
- **Two columns from one source field (date + datetime).** Costs
  nothing in a view, saves repeated parsing in marts. Rule: cheap
  staging-layer derivations that ≥2 downstream models will need.
- **File name `stg_memphis__incidents.sql` (double underscore).**
  Community convention; disambiguates source name from table name
  in mixed-source projects. We adopt it from day one even though we
  currently have one source.

## Lesson 4 — Tests & docs

- **Tests on the staging output, not the raw source.** Cleanup
  (try_cast, sentinel coercion) must run first; tests assert the
  post-staging state. Source tests make sense for external SaaS
  loads but not for our self-loaded raw schema. See
  [lesson-04](lesson-04-tests-and-docs.md#test-the-staging-contract-dont-yet-test-the-source).
- **Use `data_tests:` not `tests:`.** Modern dbt key name (1.8+);
  the older form still works but throws a deprecation warning.
- **Tests on keys + business-critical columns only.** `not_null`
  + `unique` on `incident_id`, `not_null` on `offense_date`,
  singular test on date-is-not-future. We don't test every column
  — too much noise, too much build cost, too many false failures.
- **No `accepted_values` on `offense_category`.** The Memphis
  category vocabulary changes year-over-year; hardcoding a list
  would fail every time MPD adds or renames a category. The
  `relationships` test from fact-to-dim in Lesson 5 is the better
  surface for "unknown category."
- **Singular test for "no future dates" instead of a custom
  generic.** For a one-off invariant on one model, the singular
  test in `tests/assert_*.sql` is less ceremony than a parameterized
  generic. Generic tests pay off when reused across models.
- **`dbt build` is the default day-to-day command.** It interleaves
  model build and test execution, skipping downstream models when
  upstream tests fail. Saves compute and surfaces failures at the
  right layer.
- **Docs site is a developer tool, not a deployed artifact.**
  `dbt docs serve` locally is the workflow. Hosting it would add
  GitHub Pages / S3 setup with no learning payoff right now.

## Lesson 5 — Marts & star schema

- **Star schema: 3 dims + 1 fact.** Date, location, offense are
  the only dims that earn their keep (frequent filters, frequent
  groupings, non-trivial cardinality). See
  [lesson-05](lesson-05-marts-and-star-schema.md#why-three-dims-not-more-or-fewer).
- **`dim_date` is a seed CSV, not a SQL model.** Determinism +
  git-reviewability. Generation is a one-time Python script
  whose source is captured in the lesson doc.
- **Surrogate keys are `md5(coalesce(col, '__null__') || '|' || ...)`.**
  Coalesce prevents NULL columns from nulling out the hash. The
  pipe separator prevents collisions between rows like
  `('ab','cd')` and `('a','bcd')`. Lesson 6 swaps this for
  `dbt_utils.generate_surrogate_key`.
- **`date_key` is YYYYMMDD as integer, not a hash.** Already a
  good natural surrogate (compact, uniform, stable). Hashing it
  would slow joins for no benefit.
- **Construct `date_key` from `year() * 10000 + month() * 100 + day()`.**
  Portable across DuckDB and Snowflake; `strftime` would tie us
  to DuckDB.
- **NULL-bearing dim rows are kept, not collapsed to 'Unknown'.**
  Reflects real states of the world; preserves `IS NULL` filtering
  as a discovery pattern; relationships tests still pass because
  the dim contains the NULL combo.
- **Coalesce-based join from fact to dim.** Must mirror the
  coalesce pattern in the dim's hash; otherwise NULL = NULL fails
  silently and orphans fact rows. Lesson 6's `generate_surrogate_key`
  centralizes this logic.
- **`incident_count` literal-1 column on the fact.** BI-tool
  convention: aggregations read as `SUM(measure)` rather than
  `COUNT(*)`. Trivial cost, real readability win.
- **`relationships` tests on every fact-to-dim FK.** The check
  warehouses don't enforce. They prove the join never orphans —
  the only honest way to know the star schema is consistent.
