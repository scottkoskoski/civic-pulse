# Lesson 6 — Jinja, Macros & Packages

> **Goal:** Eliminate the repeated SQL patterns from earlier lessons
> by writing one custom macro and pulling in `dbt_utils` for the
> rest. Along the way: understand what Jinja is, how dbt's macro
> system works, and how `dbt deps` brings in external code.
>
> **Time:** ~2 hours.
>
> **You'll come away knowing:** what Jinja is and why dbt uses it,
> how to write and call your own macros, what `dbt_utils` provides,
> how `dbt deps` and `packages.yml` work, and the practical impact
> of refactoring repeated SQL into named helpers.

---

## What problem are we solving?

By Lesson 5, the project has accumulated two patterns that repeat
multiple times across models:

**Pattern 1 — text normalization in staging:**

```sql
nullif(lower(trim(offense_description)), '') as offense_description,
nullif(lower(trim(offense_category)),   '') as offense_category,
nullif(lower(trim(street_address)),     '') as street_address,
nullif(lower(trim(ward)),               '') as ward,
nullif(lower(trim(precinct)),           '') as precinct,
nullif(lower(trim(council_district)),   '') as council_district,
```

**Pattern 2 — surrogate-key construction in marts:**

```sql
md5(
    coalesce(ward, '__null__')             || '|' ||
    coalesce(precinct, '__null__')         || '|' ||
    coalesce(council_district, '__null__')
) as location_key
```

…repeated three times, with different column lists, across
`dim_location`, `dim_offense`, and the fact's join.

This is exactly the kind of repetition that DRY principles target.
A typo in one occurrence (a forgotten `coalesce`, a different
separator) is a silent bug — the hashes drift, the
`relationships` tests start failing, you spend an hour
diff-hunting. Names beat repetition.

dbt's answer is **Jinja macros**: parameterized SQL fragments
that compile inline. We write one for the text-normalization
pattern (custom macro, our own), and pull in `dbt_utils` for the
surrogate-key pattern (a battle-tested utility used by basically
every dbt project).

---

## Concepts introduced

- **Jinja.** A Python templating language. dbt embeds Jinja in
  every `.sql` file: anything between `{{ ... }}` (expression) or
  `{% ... %}` (statement) gets evaluated at compile time. The
  expanded result is plain SQL that the warehouse sees. Familiar
  examples already in the project: `{{ ref('stg_memphis__incidents') }}`,
  `{{ source('memphis', 'incidents') }}`, `{{ config(materialized='table') }}`.

- **Macro.** A Jinja function defined in a `.sql` file under
  `macros/` (or inside a package). The `{% macro name(args) %}...
  {% endmacro %}` block defines it; `{{ name(args) }}` calls it.
  Macros return text that gets substituted inline.

- **`dbt_utils`.** The canonical utility-macro package, maintained
  by dbt Labs. Provides ~60 macros including
  `generate_surrogate_key`, `pivot`, `unpivot`, `safe_divide`,
  `date_spine`, plus several generic tests. The most-installed
  package in the dbt ecosystem.

- **`dbt deps`.** Reads `packages.yml`, clones each declared
  package into `./dbt_packages/`. Runs once when you add or
  upgrade a package. The clone is gitignored — `packages.yml`
  is the source of truth, exactly like `requirements.txt`.

- **Compile-time vs run-time.** Jinja runs *before* SQL ever hits
  the warehouse. By the time the warehouse sees the SQL,
  `{{ clean_text('foo') }}` has been replaced with
  `nullif(lower(trim(foo)), '')`. Macros are pure text
  substitution — they cannot inspect data, only the project
  structure and the target adapter.

---

## The build, narrated

Four file changes this lesson: install `dbt_utils`, add one
custom macro, refactor three models to use the new helpers.

### 1. `packages.yml`

```yaml
packages:
  - package: dbt-labs/dbt_utils
    version: [">=1.1.0", "<2.0.0"]
```

The package reference is `org/repo` on dbt Hub (essentially a
GitHub registry). `dbt deps` clones it into
`dbt_packages/dbt_utils/`, which is gitignored.

Version constraint is the same loose-but-bounded pattern we use
for Python dependencies: pick up patch fixes automatically, never
cross a breaking major.

### 2. `macros/clean_text.sql`

```jinja
{% macro clean_text(column_name) %}
    nullif(lower(trim({{ column_name }})), '')
{% endmacro %}
```

Three things to internalize:

**`{% macro %}` vs `{{ }}`**. The `{% %}` block defines a macro;
the `{{ }}` inside it expands an expression. So the body of the
macro substitutes `column_name` into the SQL fragment.

**The macro returns SQL text.** When a model says
`{{ clean_text('offense_description') }}`, dbt's compiler renders
the body with `column_name='offense_description'` and substitutes
the result inline. The compiled SQL in `target/compiled/` will
show `nullif(lower(trim(offense_description)), '')` — identical
to what we wrote by hand in Lesson 3.

**File location matters.** Macros under `macros/` are
project-global — every model can call them without import. Naming
the file after the macro it contains is a convention (one
macro per file), which makes them easy to find via filesystem
navigation.

### 3. Refactoring `stg_memphis__incidents`

Six occurrences of the trim-lower-nullif pattern collapse to
six `{{ clean_text(...) }}` calls. The compiled SQL is identical;
the source becomes much easier to scan. The semantic content of
the model — "these are the text columns I want normalized" — is
now visible without parsing five function calls per line.

### 4. Refactoring the surrogate keys

`dim_location.sql` before:

```sql
md5(
    coalesce(ward, '__null__')             || '|' ||
    coalesce(precinct, '__null__')         || '|' ||
    coalesce(council_district, '__null__')
) as location_key,
```

After:

```sql
{{ dbt_utils.generate_surrogate_key([
    'ward',
    'precinct',
    'council_district',
]) }} as location_key,
```

Compiled output (on DuckDB):

```sql
md5(cast(coalesce(cast(ward as varchar), '_dbt_utils_surrogate_key_null_')
     || '-' || coalesce(cast(precinct as varchar), '_dbt_utils_surrogate_key_null_')
     || '-' || coalesce(cast(council_district as varchar), '_dbt_utils_surrogate_key_null_')
     as varchar)) as location_key,
```

Slight differences from what we wrote by hand:

- **Separator is `-`, not `|`.** Convention internal to dbt_utils.
- **Sentinel is `_dbt_utils_surrogate_key_null_`, not `__null__`.**
  Same idea, different string.
- **Every column gets a `cast(... as varchar)`.** Defensive — the
  macro doesn't assume the columns are strings, so it casts them
  first. Means it works correctly when one of the keys is a
  number.

These differences are why we now get *new* surrogate keys this
run. If you rebuild the marts (`dbt run --select marts`), the
`location_key` and `offense_key` values change, but the
relationships stay consistent across the fact and dim because
both sides use the macro.

**This is exactly the failure mode the macro prevents.** If we'd
kept hand-rolled hashes in the dim and switched only the fact (or
vice versa), every relationships test would fail at once.
Centralizing the hash logic in a macro is the right structural
defense.

### 5. The fact table doesn't need to join the dims anymore

In Lesson 5, the fact joined each dim with coalesce-equality to
look up the dim's surrogate key. With the macro available, we can
compute the surrogate key *directly* on the fact side from the
natural-key columns. The hash is deterministic from inputs, so
the value we compute on the fact matches the value the dim has
stored.

The lineage graph changes as a result: `fct_incidents` now
depends only on `stg_memphis__incidents`, not on the dims.
That's accurate — the fact and the dims are siblings, both
derived from staging.

The `relationships` tests still hold because:

- Every fact row computes `location_key` via the macro applied to
  its natural-key values.
- Every dim row computed `location_key` via the same macro
  applied to the same natural-key values (after `select distinct`).
- Therefore every fact `location_key` is present in the dim by
  construction.

### A Jinja feature you'll see soon: control flow

`{% if %}`, `{% for %}`, `{% set %}` are standard Jinja. They
work inside macros and inside models. A taste of what they enable:

```jinja
{% set numeric_columns = ['latitude', 'longitude', 'incident_count'] %}
select
    {% for col in numeric_columns %}
    avg({{ col }}) as avg_{{ col }}{% if not loop.last %},{% endif %}
    {% endfor %}
from {{ ref('fct_incidents') }}
```

We don't currently have a model that benefits from this pattern,
so we don't force one. But you'll encounter it in real codebases.
The `if not loop.last` idiom is the SQL-aware version of "don't
put a trailing comma" — `loop.last` is `True` only on the last
iteration of a `for` loop.

---

## Decisions & tradeoffs

### Why install `dbt_utils` instead of just rolling our own `generate_surrogate_key`?

We could. The implementation is ~10 lines of Jinja. We don't,
because:

- `dbt_utils` is maintained by dbt Labs and has shipped on tens
  of thousands of projects. Edge cases (Snowflake VARCHAR
  collations, BigQuery STRING coercion, DuckDB type quirks) are
  already handled.
- Adopting one package teaches you the whole package-management
  workflow (`packages.yml`, `dbt deps`, where the code lives).
- Future lessons or extensions might want other `dbt_utils`
  helpers (`safe_divide`, `pivot`, `date_spine`). Already having
  it installed lowers friction.

For a one-off function with no portability concerns, rolling your
own is fine. For "I'm doing the standard thing and want to be
sure I'm doing it the standard way," reach for `dbt_utils` first.

### Custom macro vs `dbt_utils` for text normalization

`dbt_utils` does not currently ship a `clean_text` equivalent.
Writing our own is the right call: the pattern is specific to our
project's staging conventions, and a 5-line macro is easy to
maintain.

In general, prefer the package macro if one exists; only roll
your own if you have a domain-specific need.

### Why compute the FK on the fact instead of joining the dim?

Two viable patterns:

**Pattern A — join the dim, copy the key out**:

```sql
left join dim_location l on (... coalesce-based join ...)
-- then: l.location_key
```

**Pattern B — compute the FK inline from natural keys** (what
we now use):

```sql
{{ dbt_utils.generate_surrogate_key(['i.ward', ...]) }} as location_key
```

Pattern A is more "warehouse-traditional" and preserves the
parent-child lineage (`fct` depends on `dim`). Pattern B is
slightly faster (no join), produces simpler SQL, and is robust
against the dim being temporarily empty during a partial rebuild.

We pick B because the macro guarantees hash equality between
sides — the join in A was always going to produce the same key
the macro computes inline. Skipping the join is structurally
cleaner.

One nuance: Pattern B requires the fact and the dim to use the
same macro arguments in the same order. We've put both in the
project; CI (in a future lesson) could enforce a project-wide
convention via custom dbt tests.

### Macro file naming: one macro per file

Some projects bundle related macros in a single file
(`text_helpers.sql`). We use one macro per file because:

- `Cmd-P / Ctrl-P` "find file" with the macro name jumps directly
  to the definition.
- `grep -r 'macro clean_text'` finds the definition; `grep -r
  'clean_text('` finds calls. Both stay readable.
- A future macro that's related but not identical (`clean_phone`,
  `clean_email`) goes in its own file — no question about where
  to add it.

Costs a few extra files, gains clarity.

### Compile time, not run time

Macros run during `dbt compile` / `dbt parse`. They cannot see
data. A macro cannot say "if this column has more than 1000
distinct values, do X" — it doesn't have access to the warehouse
when it runs.

Macros *can* call `adapter.*` functions to introspect schemas
(get list of columns, etc.), but that's still happening at
compile time via the adapter's metadata API, not by querying
data.

This is the boundary that separates dbt's transformation
philosophy from a general-purpose ETL tool: transformations are
deterministic given the SQL and the data; macros are
deterministic given the project configuration. There's no
data-dependent branching in the build itself.

---

## Run it

### Step 1 — Install dbt_utils

```bash
dbt deps
```

Expected output:

```
Installing dbt-labs/dbt_utils
Installed from version 1.x.x
```

Inspect the install:

```bash
ls dbt_packages/dbt_utils/
# README.md, dbt_project.yml, macros/, ...
```

The `dbt_packages/` directory is gitignored. `packages.yml` is
the source of truth — anyone cloning the repo runs `dbt deps` to
materialize the same package versions.

### Step 2 — Rebuild

```bash
dbt build
```

All models rebuild. The two dims and the fact get new
surrogate-key values (the dbt_utils convention differs slightly
from our hand-rolled one). All `relationships` tests still pass —
that's the proof the refactor preserved correctness.

### Step 3 — Inspect the compiled SQL

```bash
cat target/compiled/civic_pulse/models/marts/dim_location.sql
```

You'll see the `dbt_utils.generate_surrogate_key` call expanded
to its underlying `md5(cast(coalesce(...))) as location_key` SQL.
This is the proof that the refactor compiles to what we'd have
written by hand — minus the typo risk.

```bash
cat target/compiled/civic_pulse/models/staging/stg_memphis__incidents.sql
```

The `clean_text` calls have expanded to
`nullif(lower(trim(<column>)), '')`. Identical to the Lesson 3
output, but the source file is half as wide.

### Step 4 — Re-view the docs

```bash
dbt docs generate
dbt docs serve
```

The lineage graph has shifted slightly: `fct_incidents` now hangs
directly off `stg_memphis__incidents` instead of off the dims.
Both dims also hang off staging. Three siblings instead of a
chain. Take a moment to absorb the shape — it matches how the
fact and dims are conceptually derived (all from staging, in
parallel).

---

## Further reading

- [Jinja and macros](https://docs.getdbt.com/docs/build/jinja-macros) — official intro.
- [`dbt_utils` README](https://github.com/dbt-labs/dbt-utils) — the full macro catalog.
- [`generate_surrogate_key` reference](https://github.com/dbt-labs/dbt-utils#generate_surrogate_key-source) — the macro we now use everywhere.
- [`dbt deps`](https://docs.getdbt.com/reference/commands/deps) — package management.
- [Jinja template language docs](https://jinja.palletsprojects.com/) — the underlying language (Pallets project, the official source).

---

## Done when…

- [ ] `dbt deps` runs without error.
- [ ] `dbt build` passes; all tests green.
- [ ] The compiled SQL in `target/compiled/` shows your macro
      calls expanded to the underlying SQL.
- [ ] You can articulate the difference between Jinja
      expressions (`{{ }}`) and statements (`{% %}`).
- [ ] You can explain why compute-FK-inline is preferable to
      joining-the-dim when surrogate keys are macro-generated.

**Next:** [Lesson 7 — Incremental & snapshots](lesson-07-incremental-and-snapshots.md). Two
techniques for handling data that changes over time: incremental
materialization (append/merge new rows) and snapshots (track
row-level history for slowly-changing dims).
