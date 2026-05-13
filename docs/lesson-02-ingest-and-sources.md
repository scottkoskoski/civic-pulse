# Lesson 2 — Ingest & Sources

> **Goal:** Pull real Memphis crime data into the local DuckDB warehouse
> with a small Python script, then teach dbt that the raw table exists
> by declaring it as a *source*.
>
> **Time:** ~2 hours, including finding the right Socrata dataset id
> and running the loader at least once.
>
> **You'll come away knowing:** why E/L stays out of dbt and lives
> upstream, what a dbt source is and what declaring one buys you,
> how Socrata's SODA API works (pagination, app tokens), and how
> DuckDB's `read_json_auto` shortcuts a lot of boilerplate.

---

## What problem are we solving?

A dbt project transforms tables that already exist in the warehouse.
It doesn't fetch data from APIs. Something has to put rows into a
raw table before dbt can do its job.

Two design questions need answers before we write any code:

1. **Where does extraction live?** Inside the dbt project, or in a
   separate process?
2. **How does dbt know about a table it didn't create?** It needs an
   explicit declaration; otherwise referencing a non-dbt-managed
   table is brittle and undocumented.

Lesson 2's job is to answer both:

- A standalone Python script (`data-engineering/ingest/load_memphis_crime.py`)
  owns extract-and-load. We run it manually.
- A **source** declaration in `models/staging/_sources.yml` is dbt's
  way of saying "there's a table over here you should know about."
  Once declared, the rest of the project references it through
  `{{ source('memphis', 'incidents') }}`.

---

## Concepts introduced

- **ELT vs ETL.** Modern data stacks favor **ELT**: Extract from the
  source, Load raw into the warehouse, Transform inside the warehouse.
  dbt is a "T" tool. The "E" and "L" happen upstream — sometimes in
  managed tools (Fivetran, Airbyte, Stitch), sometimes in a one-off
  script like ours.

- **source (dbt term).** A configuration block in YAML that registers
  an existing table with dbt. After you declare it, models reference
  it via `{{ source('source_name', 'table_name') }}` instead of a
  raw `FROM raw.incidents`. The benefits:
  - **Portability.** The same model SQL runs against DuckDB and
    Snowflake because dbt expands `source()` to whatever physical
    name the target warehouse expects.
  - **Lineage.** Sources are nodes in the dbt DAG. `dbt docs`
    renders them upstream of everything that references them.
  - **Quality gates.** You can attach tests and freshness checks to
    a source. Lesson 4 covers this.
  - **Change locality.** If the raw schema name ever changes, you
    edit one YAML field instead of grepping every model.

- **Socrata SODA API.** Most US open data portals (including
  data.memphistn.gov) run on Socrata. Each dataset has a unique
  4-character + 4-character id called a *4-by-4* (e.g. `abcd-1234`),
  and you can query it as JSON at
  `https://data.memphistn.gov/resource/{id}.json`. Standard query
  parameters (`$limit`, `$offset`, `$where`, `$select`) work like
  SQL clauses. App tokens lift rate limits.

- **Idempotent load.** A pipeline step is idempotent if running it
  twice has the same effect as running it once. Our loader uses
  `CREATE OR REPLACE TABLE` so any number of runs leave you with
  exactly one raw table, freshly populated.

- **DuckDB `read_json_auto`.** A built-in table function that reads
  a JSON file and infers the schema. Combined with newline-delimited
  JSON (one object per line), it's a zero-ceremony way to land
  arbitrary API responses into a typed DuckDB table.

---

## The build, narrated

Three files matter this lesson: the loader, the sources declaration,
and the `.env.example` that documents the loader's configuration.

### 1. `data-engineering/ingest/load_memphis_crime.py`

The script is small enough that you should read it top-to-bottom in
your editor. A few design choices worth pulling out:

**Why a Python script and not a dbt model?**
dbt-duckdb does support Python models (dbt 1.3+). We could in
principle write `models/staging/incidents_loaded.py`. But:

- Python models compile to a "run Python, materialize the result"
  step that's adapter-specific. Snowflake Python models use
  Snowpark; DuckDB uses local Python. The same code doesn't always
  port cleanly.
- Extraction-from-API logic doesn't share much with transformation
  logic. Mixing them inside dbt's lifecycle complicates `dbt run`
  failures (now your `dbt run` can fail because Socrata returned a
  429, which has nothing to do with your models).
- Plain Python + DuckDB is fewer concepts.

So we keep ELT layers separate.

**Pagination loop.**

```python
while True:
    params = {"$limit": PAGE_SIZE, "$offset": offset}
    resp = requests.get(url, params=params, headers=headers, timeout=60)
    resp.raise_for_status()
    page = resp.json()
    if not page:
        break
    rows.extend(page)
    if len(page) < PAGE_SIZE:
        break
    offset += PAGE_SIZE
```

Two early-exit conditions:
- **Empty page** — defensive; shouldn't happen if `$offset` is in
  bounds, but cheap to check.
- **Short page** — Socrata only returns fewer rows than the limit
  on the final page, so a short page is an unambiguous "we're done"
  signal. We use this instead of pre-counting the dataset because
  pre-counting (`$select=count(*)`) is a second round trip we don't
  need.

`raise_for_status()` ensures HTTP errors fail the script loudly
rather than silently truncating the load.

**Why write to a temp JSONL file instead of bulk-inserting?**

```python
with tempfile.NamedTemporaryFile(mode="w", suffix=".jsonl", ...) as tmp:
    for row in rows:
        tmp.write(json.dumps(row) + "\n")
    tmp_path = tmp.name

con.execute(
    f"CREATE OR REPLACE TABLE {RAW_SCHEMA}.{RAW_TABLE} AS "
    f"SELECT * FROM read_json_auto(?, format='newline_delimited')",
    [tmp_path],
)
```

Three alternatives we considered and rejected:

1. **`INSERT INTO ... VALUES (?, ?, ?)` per row.** Requires knowing
   the schema up front, which we don't — Socrata returns sparse
   JSON (missing keys when a value is null). Building the right
   `INSERT` would mean union-ing every row's keys first.
2. **Convert rows to a pandas DataFrame and `con.execute("CREATE
   TABLE ... AS SELECT * FROM df")`.** Works, but pulls in pandas
   as a dependency. For a learning project that's overkill.
3. **Use DuckDB's `from_query` with a values literal.** Doesn't
   scale to tens of thousands of rows.

`read_json_auto` against a newline-delimited file is the cleanest
path: DuckDB infers types and column names, and it handles missing
keys (becomes `NULL`) gracefully.

**Why `CREATE OR REPLACE TABLE`?**

This is the idempotency lever. Every run produces a fresh, complete
table. Pros:
- Trivially correct — you can't end up with duplicated or stale rows.
- Trivially easy to reason about — the table mirrors the API's
  current state.

Con:
- Wasteful at scale. Re-loading every row on every run is fine for
  a 100k-row dataset, painful for 100M. **Lesson 7** introduces
  dbt's incremental materialization, which addresses this in the
  transformation layer. We could also rewrite the loader to do
  upserts; we don't, because keeping the loader dumb and dbt smart
  is the convention.

### 2. `models/staging/_sources.yml`

```yaml
version: 2

sources:
  - name: memphis
    description: ...
    schema: raw
    tables:
      - name: incidents
        description: ...
```

Three small but consequential design choices:

**`name: memphis` vs `name: memphis_crime`.**
The source name is the namespace, not the dataset description.
"Memphis" suggests "data from Memphis" — leaving room for non-crime
datasets later (311 calls, building permits, etc.) without renaming
anything. Source names should be short and stable.

**`schema: raw`.**
The physical schema in DuckDB. dbt joins this with the table
`name:` to resolve `{{ source('memphis', 'incidents') }}` to
`raw.incidents`. If the loader ever lands data elsewhere, this is
the one field that has to change.

**Table name `incidents`, not `memphis_incidents`.**
Inside the `memphis` namespace, the `memphis_` prefix would be
redundant. The reference reads cleanly as
`source('memphis', 'incidents')` — "the incidents table from the
memphis source." This convention scales: if you add 311 service
requests, it's `source('memphis', 'service_requests')`.

**Filename starts with an underscore (`_sources.yml`).**
Project-level config files (sources, tests, model docs) conventionally
get an underscore prefix so they sort to the top of directory
listings. The model SQL files (Lesson 3 onward) won't have it, so
the eye can quickly spot config vs. content.

### 3. `.env.example`

We ship a template, not a real `.env`. `.env` is gitignored to
prevent leaking the app token. The template documents what
environment variables the loader reads, with one-line explanations
of where to find each value.

`python-dotenv`'s `load_dotenv()` (called at the top of `main()`)
reads `.env` from the current working directory if it exists, and is
a no-op otherwise. That means CI environments that inject env vars
directly (no `.env` file) still work; local dev with a `.env` file
also works.

---

## Decisions & tradeoffs

The big ones beyond what's above:

### Why not hardcode the Socrata dataset id?

The Memphis open data team occasionally republishes datasets under
new ids. A hardcoded constant rots silently and produces a 404 on
the next breaking change. Reading the id from the environment forces
the user to confirm it once during setup, after which it lives in
`.env` and is forgotten.

### Why not pin a date range?

The loader pulls *everything*. Adding `$where=offense_date >= 'X'`
would shrink the load, but:
- It's premature optimization on a dataset this size (Memphis is
  not Chicago).
- Future-dated incidents are a real-world data-quality bug we'll
  *want* to surface in staging tests (Lesson 4).
- The dim_date seed in Lesson 5 needs a known min/max range; pulling
  everything makes that range honest.

Adding a date filter is a one-line change later if needed.

### Should the script be a CLI with argparse?

For a single-purpose loader with three configuration values, env
vars + dotenv is plenty. Real production loaders often add argparse
for flags like `--dry-run` or `--limit`. We're not building those
because we'd never use them in this project. Each line of code we
don't write is one we don't have to maintain.

### Why declare the source in `models/staging/` and not `models/`?

dbt convention: sources are conceptually upstream of staging, so
their YAML lives alongside the staging models that consume them.
This makes lineage navigation easy — open the staging folder and
you see both the source declaration and the models built on top of
it. Larger projects sometimes hoist sources into a `models/sources/`
subfolder; for our scale, alongside the consumers is cleaner.

---

## Run it

### Step 1 — Find the Socrata dataset id

1. Open https://data.memphistn.gov in a browser.
2. Search for "incidents" or "crime."
3. Pick the dataset that looks like MPD's primary incident feed
   (something like "Memphis Police Department Public Safety
   Incidents"). Click into it.
4. The URL ends in `/resource/abcd-1234.json` (or you can find the
   id in the "API" tab on the dataset page). Copy the `abcd-1234`
   part — that's the 4-by-4.

### Step 2 — Configure `.env`

```bash
cp .env.example .env
# Edit .env, paste the dataset id into SOCRATA_DATASET_ID=
```

Optional: register at https://dev.socrata.com, generate an app
token, and paste into `SOCRATA_APP_TOKEN=`. You only need this if
you start hitting 429 rate-limit errors.

### Step 3 — Run the loader

```bash
source .venv/bin/activate          # if not already active
python data-engineering/ingest/load_memphis_crime.py
```

Expected output (numbers vary):

```
Fetching Memphis incidents from dataset 'abcd-1234'...
  fetched page (offset=      0, rows= 50000, total=50,000)
  fetched page (offset=  50000, rows= 50000, total=100,000)
  fetched page (offset= 100000, rows= 18234, total=118,234)
Fetch complete: 118,234 rows.
Loaded 118,234 rows into raw.incidents at /path/to/civic_pulse.duckdb.
```

If anything fails, the message points at the cause:
- `SOCRATA_DATASET_ID is not set` → fill in `.env`.
- `HTTPError: 404` → wrong dataset id.
- `HTTPError: 429` → register an app token.

### Step 4 — Verify in DuckDB

```bash
duckdb civic_pulse.duckdb
```

Inside the DuckDB REPL:

```sql
.tables
-- expect to see raw.incidents

select count(*) from raw.incidents;
-- some five- or six-figure number

describe raw.incidents;
-- columns inferred by read_json_auto; most will be VARCHAR
-- since Socrata sends everything as strings.

select * from raw.incidents limit 5;
-- eyeball the data; notice column names match the Socrata schema
-- and types are mostly VARCHAR. Lesson 3 will fix that.
```

### Step 5 — Verify dbt sees the source

```bash
dbt parse
```

`dbt parse` should still succeed. To confirm dbt has registered the
source, compile a one-off reference:

```bash
dbt compile --select source:memphis.incidents
```

Even with no models, this validates the source declaration: dbt
will report "source.civic_pulse.memphis.incidents" in its output.

---

## Further reading

- [Sources (dbt docs)](https://docs.getdbt.com/docs/build/sources) — the canonical reference.
- [Socrata SODA API basics](https://dev.socrata.com/docs/endpoints) — pagination, query parameters, app tokens.
- [DuckDB `read_json` reference](https://duckdb.org/docs/data/json/overview) — the function we lean on for ingestion.
- [`.env` and `python-dotenv`](https://github.com/theskumar/python-dotenv) — for when you want to learn what `load_dotenv()` actually does.

---

## Done when…

- [ ] `python data-engineering/ingest/load_memphis_crime.py` completes and reports a non-zero row count.
- [ ] `duckdb civic_pulse.duckdb` then `select count(*) from raw.incidents;` returns the same count.
- [ ] `dbt parse` succeeds.
- [ ] `dbt compile --select source:memphis.incidents` resolves without error.
- [ ] You can answer: what does declaring a source buy you that just hardcoding `from raw.incidents` in a model wouldn't?

**Next:** [Lesson 3 — First staging model](lesson-03-staging-and-materializations.md). We finally
turn raw incidents into a clean, typed staging view — and the
project becomes end-to-end runnable for the first time.
