# Lesson 7 — Incremental Models & Snapshots

> **Goal:** Two techniques for handling data that changes over
> time. Convert `fct_incidents` to an incremental materialization
> so re-builds only process new rows; add a snapshot that captures
> the SCD-2 history of how offense descriptions get categorized
> over time.
>
> **Time:** ~2.5 hours.
>
> **You'll come away knowing:** when incremental beats table,
> how `is_incremental()` and `unique_key` work, what
> `{{ this }}` is, what an SCD-2 snapshot is and why it's a
> different beast from incremental, and the two snapshot
> strategies (`timestamp` vs `check`).

---

## What problem are we solving?

By Lesson 6, every `dbt build` re-creates `fct_incidents` from
scratch. Today that's fine — we have ~100,000 rows; rebuilding
takes a few seconds. But it has two bad properties at scale:

1. **Compute waste.** 99% of yesterday's rows are unchanged.
   Rebuilding the whole table to add today's 100 new rows is the
   same as throwing away a book and reprinting it because you
   wanted to add one page.
2. **Snowflake credit waste.** Same idea, real money. Lesson 8
   will run this against Snowflake; if the model is full-refresh
   there, every `dbt build` burns more credits than necessary.

Separately, the project has no answer to the question "what was
the data yesterday?" If MPD reclassifies an offense — moves
"shoplifting" from `theft` to `property_crime` — the current
`dim_offense` shows the new mapping. Yesterday's reports printed
from yesterday's data show the old one. Reconciliation is
manual unless the warehouse keeps history.

dbt has two distinct features for these two distinct problems:

- **Incremental materialization** for fact tables: append/merge
  only new rows per build. The table reflects the *current*
  state, but builds incrementally instead of from scratch.
- **Snapshots** for slowly-changing dimensions: a separate table
  that records every version of every row, with validity-window
  timestamps. The table reflects the *full history*.

They look superficially similar (both grow over time, both track
"new" data) but solve different problems. Lesson 7 covers both
side by side so the distinction is crisp.

---

## Concepts introduced

- **Incremental materialization.** A model config that tells dbt
  to build the table cumulatively. First run: `CREATE TABLE AS
  SELECT`. Subsequent runs: filter the SELECT to "new" rows
  (defined by you), then `INSERT` or `MERGE` them into the
  existing table.

- **`unique_key`.** A column or list of columns dbt uses to
  resolve conflicts when an incremental build encounters a row
  that already exists. Most adapters use `MERGE` (UPSERT) by
  default: matching unique-keys get updated; new ones get
  inserted.

- **`is_incremental()`.** A Jinja function dbt provides to model
  code. Returns `True` only when the table already exists and the
  current run is incremental. Used inside `{% if is_incremental() %}`
  guards to add a `WHERE` clause that filters the source to "new
  rows only."

- **`{{ this }}`.** A Jinja reference to the model being built —
  resolves to the fully-qualified physical name (`marts.fct_incidents`).
  Used inside incremental models to query the *existing* table,
  typically to compute the high-water mark for the incremental
  filter.

- **`--full-refresh`.** A CLI flag that forces an incremental
  model to rebuild from scratch (`DROP + CREATE`). Use after
  schema changes, after fixing a bug in the model, or whenever
  you want a clean rebuild.

- **Snapshot.** A separate dbt resource (not a model) that
  captures the SCD-2 history of a queryable source.
  `dbt snapshot` runs it; it does NOT run as part of `dbt run`
  or `dbt build` by default. (You can wire it into `dbt build`
  via the snapshot-paths config, which the default project does;
  it's worth understanding the separation regardless.)

- **SCD type 2.** "Slowly Changing Dimension, type 2." A pattern
  for tracking history: when a tracked attribute changes for a
  given key, close the old row (set `valid_to = now`) and insert
  a new row (`valid_from = now`). The table grows monotonically;
  any historical query joins on `valid_from <= as_of <
  valid_to`.

- **Snapshot strategy: `timestamp` vs `check`.** Two ways
  snapshots detect changes:
  - `timestamp`: the source has a "last updated" column dbt can
    trust. Cheap — dbt only inserts rows whose timestamp moved.
  - `check`: dbt diffs the source row against the snapshot row
    column-by-column on each run. Slower but works against
    sources that don't have an update-time column. We use this.

---

## The build, narrated

Two file changes this lesson: rewrite `fct_incidents.sql` to be
incremental, and add the snapshot.

### 1. Incremental `fct_incidents.sql`

The diff from Lesson 6 is in two places: the config block and a
Jinja guard inside the first CTE.

**Config block:**

```jinja
{{ config(
    materialized='incremental',
    unique_key='incident_id',
    on_schema_change='append_new_columns'
) }}
```

Three settings:

- `materialized='incremental'` — switches from table-as-select
  to the incremental build path.
- `unique_key='incident_id'` — the column dbt uses to decide
  whether a row in the new batch is an insert or an update.
  Matching rows get merged; new ones get inserted.
- `on_schema_change='append_new_columns'` — what to do when the
  model's SELECT produces a column the existing table doesn't
  have. The default is `ignore` (silently drop new columns);
  `append_new_columns` is safer because schema additions don't
  silently lose data. Other options: `sync_all_columns` (mirror
  every change including drops), `fail` (refuse to build).

**Incremental filter:**

```jinja
{% if is_incremental() %}
where offense_datetime >= (
    select coalesce(max(offense_datetime), '1900-01-01'::timestamp)
         - interval '7 days'
    from {{ this }}
)
{% endif %}
```

This says "on incremental builds, only pull staging rows whose
`offense_datetime` is newer than the latest one we've already
stored, minus 7 days." The 7-day lookback is the **lateness
budget**: it catches rows that the source backdates after the
fact (data-entry lag is real). Merging by `incident_id` then
deduplicates the overlap window.

The `{% if is_incremental() %}` guard means the filter is *only*
applied during incremental runs. On the first build (when
`is_incremental()` is False) the filter is skipped and the
SELECT scans the full staging table. Same on `--full-refresh`.

**Why `'1900-01-01'::timestamp` as the coalesce default?**
On the very first run, `select max(offense_datetime) from
{{ this }}` would fail because `{{ this }}` doesn't exist yet —
except `is_incremental()` is False on the first run, so the guard
skips the filter entirely and this case never executes. The
coalesce default protects against the rarer scenario where the
table exists but happens to be empty (e.g., after a manual
truncate). Belt-and-suspenders.

### 2. The snapshot file

```jinja
{% snapshot snap_offense_categories %}

{{ config(
    target_schema='snapshots',
    unique_key='offense_description',
    strategy='check',
    check_cols=['offense_category'],
) }}

select distinct
    offense_description,
    offense_category
from {{ ref('stg_memphis__incidents') }}
where offense_description is not null

{% endsnapshot %}
```

Several non-obvious decisions baked in:

**Snapshot lives in `snapshots/`, not `models/`.** A separate
top-level directory, registered in `dbt_project.yml` via
`snapshot-paths: ["snapshots"]`. Snapshots have a different
lifecycle from models (they accumulate history rather than
rebuilding), so they live in their own folder.

**`target_schema='snapshots'`** puts the snapshot in its own
schema, separate from `marts`. Easier ad-hoc queries: "give me
all historical versions" → `select * from snapshots.snap_offense_categories`.

**`unique_key='offense_description'`, not `'offense_key'`.**
This is the most important design choice. We need a key that is
stable across the changes we want to track. `offense_key` is the
md5 hash of (category, description) — changing the category
changes the key, which would make the snapshot see "a brand new
row" instead of "a changed row." `offense_description` is the
upstream natural key whose categorization we're tracking;
*that's* what stays stable.

**`strategy='check'`, `check_cols=['offense_category']`.** The
source has no "last updated" timestamp, so we can't use the
`timestamp` strategy. `check` tells dbt: "diff
`offense_category` between the current row and the existing
snapshot row; if it changed, record a new version."

**`select distinct`.** A snapshot's SELECT must return one row
per unique_key. Staging has many incidents per offense_description;
distinct collapses that down. (The alternative — letting
`select * from stg_memphis__incidents` include duplicate
descriptions — would make `unique_key` ambiguous and the snapshot
refuse to run.)

### What columns the snapshot adds

After the first `dbt snapshot` run, the snapshot table has the
columns from the SELECT plus four dbt-managed columns:

| Column | Purpose |
|---|---|
| `dbt_scd_id` | A md5 hash dbt computes per snapshot row version. Primary key of the snapshot. |
| `dbt_updated_at` | The "last seen" timestamp from the snapshot run. |
| `dbt_valid_from` | When this version of the row became active. |
| `dbt_valid_to` | When this version stopped being active. NULL means "still active." |

A historical query then looks like:

```sql
select offense_category
from snapshots.snap_offense_categories
where offense_description = 'shoplifting'
  and dbt_valid_from <= '2023-06-15'
  and (dbt_valid_to is null or dbt_valid_to > '2023-06-15');
```

---

## Decisions & tradeoffs

### Incremental vs full-refresh: when does the tradeoff flip?

Full-refresh is fine when:
- The model is small (< a few million rows).
- The source SQL is fast.
- You're iterating on model logic and want immediate full
  effect.

Incremental wins when:
- The model is large (tens of millions of rows or more).
- The source SQL is expensive (window functions over the whole
  table, etc.).
- The cost of running the build dominates your data engineering
  bill.

Our model is small, so the incremental switch is purely
pedagogical. In a real project of this size, you'd leave
`fct_incidents` as a table — the simplicity outweighs the
compute savings.

### Why a 7-day lookback?

The lookback is the **data lateness budget**. Rows whose
`offense_datetime` is older than the window get permanently
excluded from incremental updates. If MPD backdates an incident
by 30 days after the fact, our incremental run won't catch it
unless we widen the window or do periodic full-refreshes.

Pick the window based on the source's actual lateness behavior:
- Real-time streaming sources: minutes.
- Daily-batched operational data: 1-3 days.
- Manual data entry with retroactive corrections: 7+ days.
- Anything else: instrument and measure before guessing.

A common production pattern is "incremental on Tuesday-Sunday,
full-refresh on Monday" — caps the divergence at one week.

### Snapshot vs incremental: what's actually different?

| | Incremental | Snapshot |
|---|---|---|
| Result | Current state of the data | Full history |
| Trigger | `dbt run` / `dbt build` | `dbt snapshot` (or `dbt build`) |
| Adds rows? | Yes, for new keys | Yes, for new keys *and* for changed keys |
| Updates rows? | Yes, matching `unique_key` | No — closes old row, inserts new one |
| Schema | The model's column list | The SELECT's columns + 4 dbt columns |
| Use case | Append/merge big fact tables efficiently | Track how data changed for slowly-evolving dimensions |

The headline distinction: incremental gives you the current
state efficiently; snapshots give you historical state with
some efficiency cost.

### Why snapshot at staging grain, not at dim_offense grain?

Two valid choices:

1. **Snapshot the dim.** Run snapshot against `{{ ref('dim_offense') }}`.
   Simpler conceptually.
2. **Snapshot from staging.** What we did — `select distinct` from
   the staging model and track those rows.

We chose option 2 because:
- The dim's surrogate key (`offense_key`) is derived from the
  attributes we want to track. Changing category changes the key,
  so a snapshot keyed on `offense_key` would see "new rows"
  instead of "changed rows."
- The staging layer has the natural keys we need
  (`offense_description`).
- Snapshotting from staging is one logical hop closer to the
  source-of-truth, which is the right place for historical
  fidelity.

Option 1 with `unique_key='offense_description'` would also
work, but it adds a hop without changing the semantics. Direct
from staging is cleaner.

### `dbt build` vs `dbt snapshot`

`dbt build` runs snapshots by default if `snapshot-paths` is
configured. The order is: seeds → snapshots → models → tests.
That's what we want — snapshots run before models because the
snapshot table can be referenced by models (a model could
`select * from {{ ref('snap_offense_categories') }}` to get
historical categorization).

You can also run snapshots in isolation with `dbt snapshot`, or
schedule them on a different cadence than your models. For a
slowly-changing dim, weekly snapshots may suffice even if models
run daily.

---

## Run it

### Step 1 — Rebuild with the new fact

```bash
dbt build
```

First time after the refactor, `fct_incidents` is built fresh
(full-refresh equivalent). Subsequent `dbt build` runs will
process only the lookback window.

### Step 2 — Confirm incremental behavior

Inspect the run-results SQL:

```bash
cat target/run/civic_pulse/models/marts/fct_incidents.sql
```

On the very first build, this is a `create or replace table ...
as (...)` — no incremental logic. Run `dbt build` again:

```bash
dbt build --select fct_incidents
```

Now inspect `target/run/civic_pulse/models/marts/fct_incidents.sql`
again. You'll see a `merge into ... using ... on ...` statement
(or, depending on adapter, `delete + insert`) — the incremental
execution path. The `WHERE offense_datetime >= ...` filter has
expanded.

### Step 3 — Force a full-refresh when you want one

```bash
dbt build --select fct_incidents --full-refresh
```

This drops + recreates the table from scratch. Use after schema
changes, after fixing a model bug, or anytime you suspect the
incremental state has drifted.

### Step 4 — Run the snapshot

```bash
dbt snapshot
```

Or, equivalent, `dbt build` (which runs snapshots automatically).
On the first run, you'll see:

```
1 of 1 START snapshot snapshots.snap_offense_categories ........ [RUN]
1 of 1 OK snapshot snapshots.snap_offense_categories ........... [SELECT N in 0.x]
```

…where N is the number of distinct offense_description values.

### Step 5 — Inspect the snapshot

```bash
duckdb civic_pulse.duckdb
```

```sql
.tables
-- snap_offense_categories now lives in the snapshots schema

select
    offense_description,
    offense_category,
    dbt_valid_from,
    dbt_valid_to
from snapshots.snap_offense_categories
limit 10;

-- dbt_valid_to is NULL for currently-valid rows
-- (which is every row on the first run).
```

### Step 6 — Simulate a category change (optional)

If you want to actually see the SCD-2 behavior in action, you
can fake a change. In the DuckDB CLI:

```sql
-- Pick one description and reclassify it
update raw.incidents
set offense_category = 'reclassified_test'
where offense_description = 'theft of motor vehicle';

-- Rebuild the staging model so the change propagates
```

```bash
dbt run --select stg_memphis__incidents
dbt snapshot
```

Now query the snapshot again:

```sql
select
    offense_description,
    offense_category,
    dbt_valid_from,
    dbt_valid_to
from snapshots.snap_offense_categories
where offense_description = 'theft of motor vehicle'
order by dbt_valid_from;
```

You'll see two rows:
- The original, with the real category, `dbt_valid_to` set to
  the snapshot timestamp.
- The reclassified one, with `dbt_valid_to = NULL` (currently
  active).

Revert when you're done so subsequent builds use real data:

```sql
update raw.incidents
set offense_category = <original_category>
where offense_description = 'theft of motor vehicle';
```

```bash
dbt run --select stg_memphis__incidents
```

(The snapshot will *not* "undo" the previous record — it now
considers the original category as the new state, and inserts a
third historical row. That's correct SCD-2 behavior: the history
is monotonic.)

---

## Further reading

- [Incremental models](https://docs.getdbt.com/docs/build/incremental-models) — the canonical reference.
- [Configuring incremental models](https://docs.getdbt.com/docs/build/incremental-strategy) — `merge`, `append`, `delete+insert`, `insert_overwrite`.
- [Snapshots](https://docs.getdbt.com/docs/build/snapshots) — the official intro.
- [Kimball's "The Data Warehouse Toolkit", ch. 5](https://www.kimballgroup.com/data-warehouse-business-intelligence-resources/books/data-warehouse-dw-toolkit/) — the original SCD typology (types 0-6). SCD-2 is the most common.

---

## Done when…

- [ ] `dbt build` succeeds; the run results show `fct_incidents`
      using a `merge` (or adapter-equivalent) statement.
- [ ] A second `dbt build` runs faster on `fct_incidents` than
      the first.
- [ ] `dbt build --full-refresh --select fct_incidents` rebuilds
      from scratch.
- [ ] `snapshots.snap_offense_categories` exists and contains
      `dbt_valid_from` / `dbt_valid_to` columns.
- [ ] You can describe in one sentence each:
  - Why we don't snapshot the dim directly.
  - The difference between incremental and snapshot.
  - When `is_incremental()` returns True vs False.

**Next:** [Lesson 8 — Port to Snowflake](docs/lesson-08-port-to-snowflake.md). With the
project in working order on DuckDB, we add a Snowflake target
and prove the same models build against both warehouses.
