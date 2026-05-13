# Lesson 8 — Port to Snowflake

> **Goal:** Add a Snowflake target alongside the existing DuckDB
> target. The same models, snapshots, seeds, and tests build
> against both warehouses — proving the project is genuinely
> adapter-portable.
>
> **Time:** ~3 hours, including Snowflake account creation and
> the one-time raw-data load.
>
> **You'll come away knowing:** how to sign up for a Snowflake
> trial, the minimum Snowflake objects (warehouse, database,
> schema, role) a dbt project needs, how `COPY INTO` from an
> internal stage works, what dbt's `--target` flag does, and
> the few dialect differences between DuckDB and Snowflake
> that matter at our scale.

This is the capstone. Up to now, dbt has felt like "a tool that
runs SQL against DuckDB." After today you'll have a viscerally
clearer sense of what dbt actually provides: **the same project
description, applied to a different warehouse, produces the same
analytical result.** That portability is the value proposition.

---

## What problem are we solving?

You've built a working ELT project against a local file. That's
great for learning and prototyping, but real workloads live in
warehouses you don't host yourself — Snowflake, BigQuery,
Redshift, Databricks. To go from "I learned dbt" to "I can do
this in a job," you need to have run the project against a real
managed warehouse at least once.

Lesson 8 does that. Specifically:

1. Create a Snowflake trial account ($400 of free credit, more
   than enough).
2. Provision the minimum objects: a warehouse, a database, four
   schemas, and a stage.
3. Export the DuckDB raw table to Parquet and `COPY INTO`
   Snowflake.
4. Add a `snowflake` target to `~/.dbt/profiles.yml`.
5. Run `dbt build --target snowflake` and watch the same DAG
   build against a new warehouse.

If the project really is portable, the dbt command in step 5
should "just work." We'll find out.

---

## Concepts introduced

- **Snowflake account / region / URL.** Every Snowflake account
  has an identifier of the form `<account>-<region>` (e.g.
  `abc12345-us-east-1`). The web URL is
  `https://<account>.snowflakecomputing.com/`. Both are needed in
  the dbt profile.

- **Warehouse (in Snowflake).** A compute resource. Sized
  XSMALL (1 credit/hour) through 6X-LARGE. For our scale,
  XSMALL is plenty. Snowflake bills by warehouse-time, so we
  configure auto-suspend (`60` seconds) and auto-resume to avoid
  paying for an idle warehouse.

- **Database, schema, table, view (in Snowflake).** Standard
  three-tier naming. Schemas are namespaces inside a database;
  tables and views live inside schemas. Our project uses
  `CIVIC_PULSE` as the database with `RAW`, `STAGING`, `MARTS`,
  `SNAPSHOTS` as schemas.

- **Role.** Snowflake's RBAC primitive. Permissions get granted
  to roles; users get assigned roles. The trial account ships
  with an `ACCOUNTADMIN` role that has full access; that's what
  we'll use here. A real production deployment would create a
  dedicated `DBT_RUNNER` role with narrower permissions.

- **Stage.** A storage location inside or alongside Snowflake
  that holds files before they're loaded into tables.
  **Internal stages** are Snowflake-managed object storage you
  upload to via SnowSQL's `PUT` command. **External stages**
  point at S3/GCS/Azure buckets you manage. We use an internal
  stage to avoid the cloud-account-setup detour.

- **`COPY INTO`.** Snowflake's bulk-load statement. Reads files
  from a stage and inserts rows into a table. We pair it with
  Snowflake's `INFER_SCHEMA` to auto-generate the table from the
  Parquet's metadata.

- **dbt target.** The named connection block under `outputs:`
  in `profiles.yml`. `dbt run` uses the default target;
  `dbt run --target snowflake` overrides for one invocation.

- **Schema and dialect portability.** dbt models are *mostly*
  warehouse-agnostic — `ref()` and `source()` produce the right
  fully-qualified names per target, materializations compile to
  adapter-specific DDL, and built-in macros (including
  `dbt_utils.generate_surrogate_key`) handle SQL-dialect
  differences internally. The 10% that doesn't auto-port:
  functions used directly in your SQL (`strftime`, dialect-
  specific date arithmetic, regex flavors). We chose those
  carefully in earlier lessons so the project ports without
  edits.

---

## The build, narrated

### 1. Sign up for the Snowflake trial

Go to https://signup.snowflake.com/.

- Pick **Standard** edition (cheapest; sufficient).
- Pick a region close to you (latency only matters for
  interactive queries; the project is small either way).
- Note your **account identifier** when the welcome email
  arrives — it's the part of your URL before
  `.snowflakecomputing.com`.

Activate the account via the email link; sign in to the web
console.

### 2. Run the setup SQL

In the Snowflake web console, click "Worksheets" → "+
Worksheet" → paste in the contents of
`data-engineering/snowflake/01_setup.sql` → click Run All.

The script:

```sql
create database if not exists civic_pulse;
create warehouse if not exists compute_wh
  with warehouse_size = 'XSMALL'
  auto_suspend = 60
  auto_resume = true
  initially_suspended = true;

use database civic_pulse;
create schema if not exists raw;
create schema if not exists staging;
create schema if not exists marts;
create schema if not exists snapshots;

create stage if not exists raw.parquet_stage
  file_format = (type = 'parquet');
```

What each statement is for:

- **Database** — top-level namespace for the project. Mirrors
  the DuckDB file's role.
- **Warehouse `COMPUTE_WH`** — the compute that runs queries.
  `XSMALL` is 1 credit/hour. `auto_suspend = 60` shuts it down
  after a minute of inactivity; `auto_resume = true` brings it
  back when a query arrives. `initially_suspended = true`
  means it starts off — you only pay when you actually query.
- **Four schemas** — mirror the DuckDB layout. dbt will create
  objects under `staging`, `marts`, `snapshots`; `raw` is for
  the table we'll `COPY INTO` from the Parquet export.
- **Stage `raw.parquet_stage`** — the upload target for the
  Parquet file.

After running the script, your trial account has everything it
needs to receive data.

### 3. Export DuckDB to Parquet

From the repo root, with the DuckDB venv active:

```bash
duckdb civic_pulse.duckdb "COPY raw.incidents TO 'incidents.parquet' (FORMAT PARQUET);"
```

This produces `incidents.parquet` in the current directory. Why
Parquet rather than CSV? Three reasons:

- **Smaller files.** Parquet is columnar + compressed; CSV is
  row-oriented uncompressed text. Our 100k-row dataset is ~20MB
  in Parquet and ~100MB in CSV.
- **Schema embedded.** Parquet files carry their schema in the
  metadata block. Snowflake's `INFER_SCHEMA` reads it and
  generates the table definition for us — no manual CREATE
  TABLE.
- **Type fidelity.** CSV loses type information (everything is
  a string); Parquet preserves it.

Verify the file:

```bash
ls -lh incidents.parquet
```

Expect something in the 10-30MB range.

### 4. Install SnowSQL (or use the web console)

We need to upload the Parquet file to the internal stage. The
quickest path is SnowSQL (Snowflake's CLI):

```bash
# macOS
brew install --cask snowflake-snowsql
# or download from: https://docs.snowflake.com/en/user-guide/snowsql-install-config
```

Connect:

```bash
snowsql -a <YOUR_ACCOUNT> -u <YOUR_USER>
```

You'll be prompted for the password.

Once connected:

```sql
USE DATABASE CIVIC_PULSE;
USE SCHEMA RAW;
PUT file:///absolute/path/to/civic-pulse/incidents.parquet @raw.parquet_stage;
LIST @raw.parquet_stage;
```

`PUT` uploads the local file to the internal stage. `LIST`
confirms it arrived.

### 5. Run the COPY INTO

Back in the Snowflake web console (or in SnowSQL), run
`data-engineering/snowflake/02_copy_raw.sql`:

```sql
create or replace file format raw.parquet_format
  type = 'parquet';

create or replace table raw.incidents
  using template (
    select array_agg(object_construct(*))
    from table(
      infer_schema(
        location => '@raw.parquet_stage',
        file_format => 'raw.parquet_format'
      )
    )
  );

copy into raw.incidents
  from @raw.parquet_stage
  file_format = (format_name = 'raw.parquet_format')
  match_by_column_name = 'case_insensitive'
  on_error = 'continue';

select count(*) from raw.incidents;
```

What's happening:

- **`file format`** is a Snowflake object that bundles
  parsing options (delimiter, encoding, header behavior) under
  a name. Both `infer_schema` and `copy into` reference it,
  rather than repeating the inline options twice.
- **`infer_schema`** introspects the Parquet file's metadata
  and returns a column list. The `using template` clause
  passes that into `create table`, which then has the right
  shape without us hand-typing 20 column definitions.
- **`copy into`** reads every file in the stage that matches
  the file format and inserts rows into the table.
  `match_by_column_name` lets Snowflake pair Parquet column
  names to table column names regardless of order/case.
  `on_error = 'continue'` skips malformed rows rather than
  failing the whole load — appropriate for a one-time bulk
  ingest.

After the COPY INTO completes, `select count(*)` should match
the DuckDB row count from Lesson 2.

### 6. Update `requirements.txt`

The `dbt-snowflake>=1.8,<2.0` line is now uncommented. Reinstall:

```bash
pip install -r requirements.txt
```

You'll see `snowflake-connector-python` and a few transitive
packages get installed. Coexistence with `dbt-duckdb` is fine —
dbt picks the adapter per target.

### 7. Configure the Snowflake profile

The `profiles.yml.example` template now has the Snowflake target
uncommented. Copy and edit your real `~/.dbt/profiles.yml`:

```yaml
civic_pulse:
  target: duckdb     # leave duckdb as the default
  outputs:
    duckdb:
      ... (unchanged)
    snowflake:
      type: snowflake
      account: "{{ env_var('SNOWFLAKE_ACCOUNT') }}"
      user: "{{ env_var('SNOWFLAKE_USER') }}"
      password: "{{ env_var('SNOWFLAKE_PASSWORD') }}"
      role: "{{ env_var('SNOWFLAKE_ROLE', 'ACCOUNTADMIN') }}"
      warehouse: "{{ env_var('SNOWFLAKE_WAREHOUSE', 'COMPUTE_WH') }}"
      database: "{{ env_var('SNOWFLAKE_DATABASE', 'CIVIC_PULSE') }}"
      schema: "{{ env_var('SNOWFLAKE_SCHEMA', 'STAGING') }}"
      threads: 4
```

Then export the env vars:

```bash
export SNOWFLAKE_ACCOUNT=abc12345-us-east-1
export SNOWFLAKE_USER=your_username
export SNOWFLAKE_PASSWORD=...
# role/warehouse/database/schema have defaults that match the setup script
```

(Or stash these in `.env` and `source .env`.)

`env_var('NAME')` is dbt's way of reading environment variables
at compile time. Never paste a real password into the YAML —
even though `~/.dbt/profiles.yml` is outside the repo, env-var
references are still the right hygiene.

### 8. Verify and run

```bash
dbt debug --target snowflake
```

Expected output: `All checks passed!` with the Snowflake adapter
listed.

```bash
dbt build --target snowflake
```

This runs the entire DAG against Snowflake:

- Seeds → `CIVIC_PULSE.MARTS.DIM_DATE` (loaded from CSV).
- Snapshot → `CIVIC_PULSE.SNAPSHOTS.SNAP_OFFENSE_CATEGORIES`.
- Staging view → `CIVIC_PULSE.STAGING.STG_MEMPHIS__INCIDENTS`.
- Mart tables → `CIVIC_PULSE.MARTS.{DIM_LOCATION, DIM_OFFENSE,
  FCT_INCIDENTS}`.
- All tests.

Compare timings to the DuckDB build. Snowflake's per-statement
overhead is higher; the warehouse takes a few seconds to spin
up from suspend. For tiny models the DuckDB build is faster end-
to-end; the Snowflake build is roughly the same once the
warehouse is warm.

### 9. Confirm everything works in Snowflake

In the Snowflake web console:

```sql
use database civic_pulse;

select count(*) from marts.fct_incidents;
-- should match what you got on DuckDB

select
    d.year,
    o.offense_category,
    sum(f.incident_count) as incidents
from marts.fct_incidents f
join marts.dim_date    d using (date_key)
join marts.dim_offense o using (offense_key)
where d.year between 2022 and 2024
  and o.offense_category is not null
group by 1, 2
order by 1, 3 desc
limit 20;
```

The same analytical query from Lesson 5 runs against the
Snowflake build. Same answer. That's the win.

---

## Decisions & tradeoffs

### Internal stage, not external

External stages (S3, GCS, Azure Blob) are the production
pattern — they let you load gigabytes of data without uploading
through your laptop. We use an internal stage because:

- No second cloud account to set up.
- No IAM/IAM-role/policy juggling.
- The dataset is small enough (~20MB Parquet) that uploading via
  SnowSQL takes seconds.

In a real ETL pipeline, the loader would write Parquet directly
to S3 and the stage would point there. The dbt model lineage
wouldn't change.

### `ACCOUNTADMIN` role for everything

A real Snowflake deployment defines roles like `DBT_RUNNER`
with the minimum grants: USAGE on warehouse, USAGE on database,
CREATE SCHEMA on database, OWNERSHIP on relevant schemas. The
trial account ships with `ACCOUNTADMIN` which has full access,
so for learning we use that.

The two-line addition to your `profiles.yml` if you ever
upgrade: `role: DBT_RUNNER`, plus running a one-time
permissions script that creates the role and grants. Not hard,
just out of scope today.

### Parquet, not CSV

Covered above. Worth repeating: schema-embedded files mean less
hand-typed DDL.

### `match_by_column_name`, not positional

Default `COPY INTO` assumes the Parquet columns are in the same
order as the table columns. `match_by_column_name` pairs them by
name. Safer when the Parquet was generated by a tool that
might not preserve column order.

### Why does the project work without dialect adjustments?

Three early decisions kept it portable:

- **`try_cast` exists in both DuckDB and Snowflake.** We avoided
  `safe_cast` (DuckDB-specific in some forms) and `try_to_*`
  (Snowflake-specific).
- **`year() / month() / day()` exist in both.** We used these
  instead of DuckDB's `strftime` or Snowflake's `to_char`.
- **`dbt_utils.generate_surrogate_key` handles the SQL-dialect
  differences for hashing.** Different adapters cast types
  slightly differently before `md5`; the macro abstracts that.

If we'd written `strftime(offense_date, '%Y%m%d')` in
`fct_incidents`, the Snowflake build would fail with "Unknown
function." That's the cost of not thinking about portability
early.

### What didn't port automatically

Practically nothing. Two corner cases to be aware of:

- **Identifier casing.** Snowflake folds unquoted identifiers
  to UPPERCASE; DuckDB preserves whatever case you typed. So
  `staging.stg_memphis__incidents` on DuckDB becomes
  `STAGING.STG_MEMPHIS__INCIDENTS` on Snowflake. References
  through dbt's `{{ ref(...) }}` handle this; references in
  raw SQL (e.g., your ad-hoc analytical query) may need to
  quote names if you typed them lowercase in DuckDB.
- **Snapshot timestamp types.** DuckDB stores
  `dbt_valid_from` as `TIMESTAMP`; Snowflake as
  `TIMESTAMP_NTZ`. dbt manages this; you only notice if you
  introspect column types directly.

---

## What you've built

You have a complete dbt project that:

- Pulls data from a real public API via Python.
- Lands it in a separate raw schema (ELT, not ETL).
- Transforms it through a clean staging layer with tests and
  docs.
- Builds a star-schema mart with conformed dimensions.
- Uses macros and packages to DRY repetition.
- Handles incremental builds and SCD-2 history.
- Runs against both a local file warehouse (DuckDB) and a
  managed cloud warehouse (Snowflake), with no model changes.

That's the full vocabulary of practical dbt fundamentals.

---

## Further reading

- [Connect to Snowflake (dbt docs)](https://docs.getdbt.com/docs/core/connect-data-platform/snowflake-setup) — every config option.
- [Snowflake "Getting Started" guides](https://docs.snowflake.com/en/user-guide-getting-started) — the official tour.
- [`COPY INTO` reference](https://docs.snowflake.com/en/sql-reference/sql/copy-into-table) — every option.
- [`INFER_SCHEMA`](https://docs.snowflake.com/en/sql-reference/functions/infer_schema) — the auto-table-creation function.
- [SnowSQL](https://docs.snowflake.com/en/user-guide/snowsql) — the official CLI.

---

## Done when…

- [ ] `dbt debug --target snowflake` is green.
- [ ] `dbt build --target snowflake` succeeds — same model
      count, same test count, same pass count as the DuckDB
      build.
- [ ] You've run an analytical query against
      `CIVIC_PULSE.MARTS.FCT_INCIDENTS` joined to the dims and
      it returned a sensible answer.
- [ ] You've suspended the warehouse manually
      (`alter warehouse compute_wh suspend;`) or confirmed
      auto-suspend is working — credits aren't burning while
      you're done for the day.

---

## Beyond this project

Things to revisit now that you have the fundamentals:

- **dbt Cloud** — a managed dbt scheduler with a built-in IDE,
  CI integration, and a hosted docs site. Useful when team
  collaboration matters.
- **Orchestration** — Airflow / Dagster / Prefect can schedule
  `dbt build` runs and chain them with non-dbt steps.
- **CI/CD** — GitHub Actions running `dbt build --target ci`
  on every PR. dbt's slim CI feature only builds what changed.
- **Semantic layer / MetricFlow** — dbt's metric definitions
  expose business logic to BI tools without each tool
  reinventing it.
- **Exposures, groups, contracts** — useful when multiple teams
  contribute to one project.
- **Snowflake-specific features** — zero-copy clones, time
  travel, dynamic tables, streams + tasks for streaming
  ingestion.

None of these are required to be productive with dbt. They're
the next 10% once the fundamentals you just learned feel
automatic.
