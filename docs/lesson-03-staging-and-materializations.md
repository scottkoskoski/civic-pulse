# Lesson 3 — First Staging Model & Materializations

> **Goal:** Build your first real dbt model — a staging view over
> raw incidents — and understand what dbt's materializations
> actually mean at the SQL level.
>
> **Time:** ~2.5 hours, including the inevitable column-name
> reconciliation against your actual Socrata data.
>
> **You'll come away knowing:** the staging-model convention and
> why every project uses it, what `ref()` does and how it differs
> from `source()`, what the four built-in materializations
> (`view`, `table`, `incremental`, `ephemeral`) compile down to,
> and how dbt builds models in dependency order.

This is the **end-to-end milestone**. By the end of this lesson,
`dbt run` will execute against the warehouse and produce a real
queryable object. From here forward, every lesson is an addition.

---

## What problem are we solving?

Raw data is hostile to humans. Socrata's response is JSON-blobby:
inconsistent casing, types-as-strings, sentinel values like
`(0, 0)` masquerading as coordinates, columns named with `:` prefixes
that don't quote nicely in SQL. Building dimensional models directly
on top of that mess means every downstream model re-implements the
same cleanup logic. Tests fail because of stylistic noise, not data
problems. BI users complain about lat/lng being strings.

The **staging layer** is the project's contract with the rest of
the world. Its job is mechanical:

- Rename columns to a project-wide convention (snake_case, descriptive).
- Coerce types (strings → dates, doubles, integers).
- Normalize values that should be canonical (trim whitespace, lower
  string keys).
- Surface sentinel-to-NULL conversions so that the rest of the
  project doesn't have to think about them.

Everything downstream — marts, snapshots, custom analyses —
references staging models, not the raw source. That single rule
keeps the project sane as it grows.

---

## Concepts introduced

- **Staging model.** A dbt model that does light, mechanical
  cleanup of a single source table. By convention, one staging
  model per source table, and the file is named
  `stg_<source>__<table>.sql`. Materialized as a `view` by default
  so it's always fresh and cheap.

- **The `stg_<source>__<table>` naming convention.** Double
  underscore separates the source name from the table name. Why
  this matters: in a project pulling from many sources, you'll
  have `stg_memphis__incidents` next to `stg_stripe__charges`
  next to `stg_salesforce__accounts`. The pattern reads cleanly
  in alphabetical sort and the source is the first thing the eye
  catches. Single underscores get visually swallowed by the
  source/table separators inside each name (e.g.
  `stg_memphis_incidents` vs `stg_memphis_offenses` looks like
  one long compound name; the double underscore disambiguates).

- **`ref()`.** dbt's most important function. Used inside a model
  to reference another model (not a source): `{{ ref('stg_memphis__incidents') }}`.
  dbt resolves it to the fully-qualified physical name at compile
  time and — critically — uses it to build the dependency graph.
  Edge cases that `ref()` handles automatically: schema names that
  differ between dev/prod, run order (downstream models build
  after their upstream), parallelism (independent branches build
  concurrently).

- **Materialization.** *How* dbt persists the result of a model's
  SELECT. The four built-ins:
  - **view** — `CREATE OR REPLACE VIEW`. No storage, no rebuild
    cost; the SELECT runs every time someone queries the view.
  - **table** — `CREATE OR REPLACE TABLE AS SELECT`. Costs storage;
    fast to query because the result is materialized.
  - **incremental** — first run is `CREATE TABLE AS`; subsequent
    runs `MERGE` or `INSERT` only new/changed rows based on a
    `unique_key` and a filter. Covered in Lesson 7.
  - **ephemeral** — no physical object at all; the SELECT is
    inlined as a CTE into any model that `ref()`s it. Niche.

- **`try_cast` (DuckDB).** Like `cast`, but returns NULL instead
  of raising on bad input. Snowflake has the same function. We use
  it so a single malformed row doesn't fail the entire build.

---

## The build, narrated

One model file lands this lesson:
`models/staging/stg_memphis__incidents.sql`. Walk through it in
your editor; the comments are part of the lesson.

### The CTE-first pattern

```sql
with source as (

    select * from {{ source('memphis', 'incidents') }}

),

renamed as (

    select
        incident_number as incident_id,
        ...
    from source

)

select * from renamed
```

Three named CTEs (`source`, `renamed`, then the final select). This
is the project-wide convention; every model follows the same
shape:

1. **`source` / `import` CTEs** — `select *` from each upstream
   `source()` or `ref()`. One per upstream. This is a no-op SQL
   layer that exists only for readability: the rest of the model
   references `source.foo` instead of `{{ source(...) }}.foo`,
   making the actual transformation easier to scan.

2. **One or more named CTEs for the actual transformation logic.**
   In a staging model that's usually just `renamed`. Marts will
   have several (`joined`, `aggregated`, `final`).

3. **A trivial `select * from <last_cte>`** at the bottom. dbt's
   compiled SQL is one expression; the bottom-most select is
   what becomes the view's body.

This isn't a dbt requirement. It's a community convention strong
enough that you should treat it as one. The payoff: every model
in the project has the same top-to-bottom structure, so reading
unfamiliar models is fast.

### The `{{ config(materialized='view') }}` block

```sql
{{ config(materialized='view') }}
```

This sits at the very top of the file. It's redundant in this
case — `dbt_project.yml` already defaults staging models to
`view`. We include it explicitly because:

- It makes the SQL file self-describing. You can read one .sql
  file and know what dbt will do with it, without cross-referencing
  the project config.
- Future-you might move this file out of `models/staging/` and
  lose the folder-level default. An explicit config is robust.
- Inline `config()` blocks **override** project-level defaults, so
  this is also the mechanism for "this one model needs to be a
  table even though it's in the staging folder." Worth knowing
  about, even if we don't use that escape hatch here.

### Type coercion with `try_cast`

```sql
try_cast(offense_date as date)        as offense_date,
try_cast(offense_date as timestamp)   as offense_datetime,
```

A single Socrata `offense_date` value typically encodes both date
and time (`2023-04-15T13:42:00.000`). We extract both
representations so downstream models don't have to re-parse:
`offense_date` for the dim_date join in Lesson 5, `offense_datetime`
for hour-of-day analyses.

**Why `try_cast` and not `cast`?** A malformed value in a single
row will make `cast(... as date)` fail the entire `dbt run`. With
`try_cast`, the bad row becomes NULL and the build succeeds.
We'll catch the NULLs with a `not_null` test in Lesson 4, which is
the right place to surface data-quality issues: the build runs,
*then* tests report the problem. This separates "the pipeline
works" from "the data is clean."

### Sentinel-to-NULL coercion

```sql
case
    when try_cast(latitude as double) = 0 then null
    else try_cast(latitude as double)
end as latitude
```

Several Memphis records arrive with `latitude=0, longitude=0`,
which an upstream system likely used to mean "unknown location."
Plotting these on a map puts them in the Atlantic Ocean
(specifically, the Gulf of Guinea). Coercing zero to NULL during
staging means every downstream consumer (BI tools, mart models,
exports) doesn't have to remember the sentinel.

This is the kind of small, locally-correct decision that lives in
staging precisely because it's correct *everywhere downstream*.
If we left it for marts to handle, every mart would have to
re-implement the same case statement.

### String normalization with `lower(trim(...))`

```sql
nullif(lower(trim(offense_description)), '') as offense_description,
```

Three composed operations:

- `trim()` strips leading/trailing whitespace. Almost always
  spurious in scraped/typed data.
- `lower()` canonicalizes casing. "ASSAULT", "Assault", and
  "assault" collapse to one bucket.
- `nullif(..., '')` converts the result of trimming-an-all-whitespace
  string from `''` to NULL, since `''` is rarely the desired
  representation of "missing."

We do this in staging because every downstream model that groups
by offense category benefits. If we deferred this to marts, the
fact model's `count(*) group by offense_category` would split
"Assault" and "assault" into separate buckets.

### What the compiled SQL looks like

After `dbt parse` or `dbt run`, look at the file dbt generated:

```
target/compiled/civic_pulse/models/staging/stg_memphis__incidents.sql
```

The Jinja (`{{ source(...) }}`, `{{ config(...) }}`) is gone; what
remains is plain SQL with the source reference expanded to
`raw.incidents`. The `compiled/` folder is your debugging tool —
when a model misbehaves, the compiled SQL is what actually ran.

There's also a `target/run/` folder containing the *executed* form
of each model — which is the compiled SQL wrapped in the
materialization's DDL. For a view model it looks like:

```sql
create or replace view staging.stg_memphis__incidents as (
    -- compiled SQL pasted in here
);
```

For a table model it would be `create or replace table ... as (...)`.
For incremental, you'd see the conditional merge logic. This is the
clearest way to understand what each materialization actually does
under the hood.

---

## Decisions & tradeoffs

### Staging is a view, not a table

We default staging to `view` in `dbt_project.yml`. Why not `table`?

**Pros of view:**
- Zero storage cost.
- Always fresh. The first time a downstream model selects from
  `stg_memphis__incidents`, the view's SELECT runs against the
  current raw data.
- Cheap to rebuild. `dbt run --select staging` is fast.

**Pros of table:**
- Faster repeated queries (the rename/cast logic is precomputed).
- Decouples downstream model performance from the staging SQL's
  complexity.

For staging — which is by definition cheap rename/cast — views
win. The transformations are simple enough that a query optimizer
inlines the view into downstream models anyway. Tables make sense
in marts (Lesson 5), where the SQL is more complex and the table
is hit many times by BI.

### Two columns from one source field (`offense_date` + `offense_datetime`)

Some teams pick one and force everyone to derive the other. We
emit both because the storage cost is irrelevant (it's a view) and
having both available means downstream models stay simple. The
rule: if a transformation is going to be needed by ≥2 downstream
models and is cheap, do it in staging once.

### Why `nullif(trim(...), '')` instead of just `trim(...)`?

`trim('   ')` returns `''`, not NULL. Many SQL queries treat `''`
and NULL identically out of habit, but they're not equivalent:
`'' = ''` is true, `NULL = NULL` is NULL (unknown). Forcing
empty-string-after-trim to NULL means downstream WHERE clauses
filter consistently with `where offense_description is not null`.

### File starts with `stg_`, not `staging_`

`stg_` is the dbt community convention. It's terse but consistent.
`staging_my_model.sql` reads awkwardly in CLI output and in lineage
graphs. The naming pattern matters because dbt resolves models by
file name (sans extension) when you use `ref()` — and you'll type
those names a lot.

### Why declare `{{ config(materialized='view') }}` when the folder default already says so?

Redundancy in exchange for locality. Reading the .sql file in
isolation tells you the materialization. If a future contributor
moves the model out of `staging/` for some reason, the inline
config travels with it.

---

## Run it

### Step 1 — Inspect the raw schema to confirm column names

Before running dbt, make sure the column names in the model match
your actual source. Open DuckDB:

```bash
duckdb civic_pulse.duckdb
```

```sql
describe raw.incidents;
```

Each row in the output is `(column_name, column_type, ...)`. Skim
the names. The model assumes columns like `incident_number`,
`offense_date`, `offense_description`, `offense_category`,
`latitude`, `longitude`, `street_address`, `ward`, `precinct`,
`council_district`. **If your actual names differ**, edit
`models/staging/stg_memphis__incidents.sql` and change the
left-hand side of each `as` clause to match what's in your
warehouse. Keep the right-hand side (the target column name)
unchanged so downstream lessons don't have to be rewritten.

### Step 2 — Run dbt

```bash
dbt run --select staging
```

Expected output:

```
Running with dbt=1.x.x
Found 1 model, 0 tests, ..., 1 source, ...

1 of 1 START sql view model staging.stg_memphis__incidents .... [RUN]
1 of 1 OK created sql view model staging.stg_memphis__incidents [OK in 0.05s]

Finished running 1 view model in N seconds.

Completed successfully

Done. PASS=1 WARN=0 ERROR=0 SKIP=0 TOTAL=1
```

### Step 3 — Inspect the result

Back in DuckDB:

```sql
.schemas
-- expect: main, raw, staging   (staging is new)

select count(*) from staging.stg_memphis__incidents;
-- should match raw.incidents row count

select * from staging.stg_memphis__incidents limit 5;
-- columns are now snake_case, types are proper

select column_name, data_type
from information_schema.columns
where table_schema = 'staging'
  and table_name   = 'stg_memphis__incidents'
order by ordinal_position;
-- confirms lat/lng are DOUBLE, dates are DATE/TIMESTAMP
```

### Step 4 — Inspect what dbt actually ran

```bash
cat target/run/civic_pulse/models/staging/stg_memphis__incidents.sql
```

This is the executed DDL — `create or replace view staging.stg_memphis__incidents as (...)` wrapping
the compiled SQL. Compare with the source file: the Jinja is
fully expanded.

### Step 5 — See the lineage graph

```bash
dbt docs generate
dbt docs serve
```

This opens a browser at `localhost:8080`. Click the "lineage graph"
icon in the bottom-right. You'll see two nodes: `memphis.incidents`
(green, source) → `stg_memphis__incidents` (blue, model). The
project is officially end-to-end runnable.

When done, `Ctrl-C` the `dbt docs serve` process. Lesson 4 will
add tests and descriptions, which makes the docs site dramatically
more useful.

---

## Further reading

- [Build your first models](https://docs.getdbt.com/docs/build/models) — official intro.
- [Materializations](https://docs.getdbt.com/docs/build/materializations) — view/table/incremental/ephemeral, in depth.
- [How we structure our dbt projects](https://docs.getdbt.com/best-practices/how-we-structure/1-guide-overview) — the source of the staging-model conventions we adopted.
- [`ref()` and `source()`](https://docs.getdbt.com/reference/dbt-jinja-functions/ref) — the canonical reference.

---

## Done when…

- [ ] `dbt run --select staging` exits with `PASS=1`.
- [ ] `select count(*) from staging.stg_memphis__incidents` matches `raw.incidents` count.
- [ ] You can describe the difference between `ref()` and `source()` in one sentence.
- [ ] You can describe what `view` and `table` materializations compile to.
- [ ] You can locate the compiled and run SQL for the model in `target/`.

**Next:** [Lesson 4 — Tests & docs](lesson-04-tests-and-docs.md). We lock in the
staging contract with generic and singular tests before building
the marts that will depend on it.
