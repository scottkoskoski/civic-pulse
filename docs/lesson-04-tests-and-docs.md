# Lesson 4 — Tests & Docs

> **Goal:** Lock in the staging contract with data tests before
> building anything on top of it, and learn to use dbt's generated
> documentation as a navigation tool.
>
> **Time:** ~2 hours.
>
> **You'll come away knowing:** the difference between generic and
> singular tests, what each built-in generic test compiles to, how
> `_stg_models.yml` doubles as both the test config and the
> documentation source, and how `dbt docs generate` produces a
> static site that's genuinely useful for project navigation.

---

## What problem are we solving?

The staging model is the **contract** the rest of the project will
depend on. Lesson 5 will build dimensions and facts that assume
`stg_memphis__incidents.incident_id` is unique and non-null, that
`offense_date` is a real date, that `latitude` is either a real
coordinate or NULL. If any of those assumptions silently break, the
marts produce wrong numbers without anyone noticing.

We want two things:

1. **Mechanical assertions** that fail the pipeline if the
   contract breaks. dbt's `dbt test` runs them on demand.
2. **Documentation** that says what each column means and what
   shape we expect the data to take, so a future reader (or
   future-you) doesn't have to reverse-engineer the model.

Both live in the same YAML file. That's not an accident — the
project says "this column is non-null and represents X" in one
place, and both the test runner and the docs site read from it.

The order is deliberate: **tests before marts.** If a downstream
model has a bug, you want to know whether the bug is in the mart
or whether the bug is in the assumptions about staging. Testing
staging first gives you a clean upstream to build on.

---

## Concepts introduced

- **Generic data test.** A reusable test defined as a Jinja macro
  that takes column-level arguments. The four built-ins:
  - `not_null` — every row must have a value.
  - `unique` — no two rows share a value (per column).
  - `accepted_values` — every value must be in a given list.
  - `relationships` — every value must exist in a referenced column
    of another model (foreign-key check).
  Generic tests live in YAML and apply to columns. `dbt test`
  expands them into SELECTs that should return zero rows.

- **Singular (data) test.** A hand-written `.sql` file in `tests/`
  that returns rows on failure. More flexible than generic tests —
  you can express any invariant SQL can express — but not reusable.
  Use singular when the test is specific to one model and one
  invariant.

- **Test severity.** Tests can be configured `severity: error`
  (default; fails the run) or `severity: warn` (logs but doesn't
  fail). Useful when a check is informational rather than blocking.
  We don't use it this lesson but it's worth knowing.

- **`_stg_models.yml`.** The schema YAML for the staging folder.
  Convention: one schema YAML per folder, prefixed `_` so it
  sorts to the top. Contains model and column descriptions and the
  generic-test directives.

- **`dbt docs generate` / `dbt docs serve`.** Builds a static HTML
  site (saved to `target/`) and serves it locally. The site
  combines the project's source code, descriptions, and lineage
  graph into one navigable browser tool. Genuinely the best way
  to explore a dbt project you didn't write.

---

## The build, narrated

Two files land this lesson: `_stg_models.yml` (the schema YAML)
and `tests/assert_incident_date_not_future.sql` (a singular test).

### 1. `models/staging/_stg_models.yml`

The file has two responsibilities, expressed in one nested
structure:

```yaml
models:
  - name: stg_memphis__incidents
    description: >
      One row per Memphis Police Department incident, ...

    columns:
      - name: incident_id
        description: ...
        data_tests:
          - not_null
          - unique

      - name: offense_date
        description: ...
        data_tests:
          - not_null

      - name: offense_description
        description: ...   # no test, just description

      ...
```

Three patterns to internalize:

**Descriptions are not optional**. Every model and every column
has one in this file. The discipline is annoying at first; the
payoff is that `dbt docs serve` becomes a tool that newcomers
actually use, instead of an empty shell.

The `>` YAML syntax is a folded scalar — lets you write multi-line
descriptions that render as a single paragraph in docs. Use it
liberally; descriptions can (and should) be longer than one line.

**`data_tests:` is the modern key name** (dbt 1.8+). The older
key `tests:` still works for backward compatibility but produces
a deprecation warning. We use `data_tests:` everywhere.

**Test order under each column doesn't matter for execution.**
dbt runs all tests in parallel (or as many as your `threads:`
setting allows). The order in the YAML is purely stylistic.

### 2. What each test compiles to

The compiled SQL is in `target/compiled/civic_pulse/models/staging/`
after a `dbt parse`. Worth reading once to demystify what tests
actually do:

**`not_null` on `incident_id`** compiles to:

```sql
select incident_id
from staging.stg_memphis__incidents
where incident_id is null
```

If this query returns any rows, the test fails.

**`unique` on `incident_id`** compiles to:

```sql
select incident_id
from staging.stg_memphis__incidents
where incident_id is not null
group by incident_id
having count(*) > 1
```

Failed rows are the *duplicated values*, not all rows that
duplicate. The `where incident_id is not null` clause means
uniqueness ignores nulls — which is why `not_null` and `unique`
are usually paired.

**`accepted_values`** (not used here, shown for completeness):

```yaml
- name: offense_category
  data_tests:
    - accepted_values:
        values: ['theft', 'assault', 'robbery']
```

compiles to:

```sql
select offense_category
from staging.stg_memphis__incidents
where offense_category not in ('theft','assault','robbery')
```

We deliberately do *not* test `offense_category` with
`accepted_values`. The Memphis dataset's category vocabulary is
not stable enough across years to hardcode a list — categories
get added and renamed. In Lesson 5 we'll instead test the foreign
key relationship between the fact table and `dim_offense`, which
naturally surfaces unknown categories.

**`relationships`** (used in Lesson 5):

```yaml
- name: offense_category
  data_tests:
    - relationships:
        to: ref('dim_offense')
        field: category
```

compiles to a left-join-where-null check confirming every value
in the child column exists in the parent.

### 3. `tests/assert_incident_date_not_future.sql`

```sql
select
    incident_id,
    offense_date
from {{ ref('stg_memphis__incidents') }}
where offense_date > current_date
```

Singular tests follow one rule: **rows returned = test failure**.
A zero-row result means "the assertion holds." This is the same
contract as generic tests; the difference is that singular tests
are hand-written rather than parameterized.

Why a singular test for this check? You could write a custom
generic test (`tests/generic/test_not_in_future.sql`), but for a
one-off assertion specific to one column on one model, the
ceremony isn't worth it. Singular tests are perfect for "I want to
assert this one specific thing about this one specific model."

The file name doubles as the test name — `dbt test` will report
it as `assert_incident_date_not_future`. Conventional prefix:
`assert_` for things that should be true. Some teams use `check_`
or no prefix; consistency within a project matters more than the
exact word.

The `{{ ref('stg_memphis__incidents') }}` is important — by using
`ref()`, this test becomes part of the lineage graph. dbt knows it
depends on the staging model and will run it after the staging
model builds. Without `ref()`, the test would still work but
wouldn't appear in the dependency graph correctly.

### 4. Why the order of operations matters

```
dbt build
```

vs.

```
dbt run && dbt test
```

`dbt build` interleaves: it builds each model and then runs the
tests attached to that model *before* moving to downstream models.
If a staging test fails, dbt skips downstream models that depend
on it. That's much better than discovering a staging failure
*after* you've spent compute building 12 broken mart models.

`dbt run && dbt test` runs everything first, then tests
everything. Useful when you specifically want all models built
regardless of test status (e.g., to inspect partial results).

Once you're past Lesson 3, **`dbt build` should be your default**.

---

## Decisions & tradeoffs

### Test the staging contract; don't (yet) test the source

dbt supports declaring tests on `source()` declarations too. We
could put `not_null` and `unique` on `_sources.yml`. We don't,
because:

- The raw source is loaded by *our* loader script and is mostly
  trusted to be whatever Socrata returned. If a raw row has a
  garbage value, we want the staging layer to surface it (via
  cleanup + tests on the cleaned column), not flag the raw layer
  as failing.
- Tests on the source would fire before staging cleanup. We
  *want* sentinel coercion and `try_cast` to run first, then test
  the cleaned result.

Tests on sources make sense when the source is genuinely
external (Fivetran-loaded SaaS data) and you want to detect
upstream contract breaks. For a self-loaded source, prefer
post-staging tests.

### Why not test on every column?

The columns without `data_tests:` are still documented but
untested. Two reasons:

1. **Cost.** Every test is a SELECT. Hundreds of tests on a model
   you're iterating on slow the build.
2. **Signal.** Tests on every column desensitize you to failures
   ("oh, another test is broken"). Focus tests on:
   - Primary/natural keys (always `not_null` + `unique`).
   - Foreign keys (`relationships` to the parent).
   - Anything that has business meaning that must hold (`offense_date`
     existing, since marts pivot on it).
   - Sentinels and edge cases worth catching early.

A column like `street_address` is free-text and can legitimately
be NULL (anonymized incidents). Testing it for non-null would
produce false failures forever.

### `data_tests:` vs `tests:`

dbt 1.8 renamed `tests:` to `data_tests:` to disambiguate from
*unit tests* (also introduced in 1.8). We use `data_tests:` to
stay on the modern key, which also makes the YAML future-proof.

### Why we generate docs but don't host them anywhere

The docs site is a developer tool. It's a navigation aid while
you're working. Hosting it as a deployed artifact has value
(team-wide reference) but adds GitHub Pages or S3 setup that's
out of scope.

If you ever want to share the docs site, `dbt docs generate`
produces a `target/` folder you can rsync somewhere. The site is
fully static.

---

## Run it

### Step 1 — Test the staging model

```bash
dbt test --select stg_memphis__incidents
```

If everything is clean:

```
Running with dbt=1.x.x
Found 1 model, 4 data tests, ..., 1 source, ...

1 of 4 START test not_null_stg_memphis__incidents_incident_id ............... [RUN]
1 of 4 PASS not_null_stg_memphis__incidents_incident_id ..................... [PASS in 0.05s]
2 of 4 START test unique_stg_memphis__incidents_incident_id ................. [RUN]
2 of 4 PASS unique_stg_memphis__incidents_incident_id ....................... [PASS in 0.06s]
3 of 4 START test not_null_stg_memphis__incidents_offense_date .............. [RUN]
3 of 4 PASS not_null_stg_memphis__incidents_offense_date .................... [PASS in 0.04s]
4 of 4 START test assert_incident_date_not_future ........................... [RUN]
4 of 4 PASS assert_incident_date_not_future ................................. [PASS in 0.03s]

Done. PASS=4 WARN=0 ERROR=0 SKIP=0 TOTAL=4
```

If any test fails, dbt prints how many rows the test returned and
where to find them:

```
4 of 4 FAIL 17 assert_incident_date_not_future ............................. [FAIL 17 in 0.03s]

Failure in test assert_incident_date_not_future (tests/assert_incident_date_not_future.sql)
  Got 17 results, configured to fail if != 0

  compiled Code at target/compiled/civic_pulse/tests/assert_incident_date_not_future.sql
```

`select * from <compiled query>` in DuckDB shows the offending
rows. That's your debugging workflow.

### Step 2 — Build + test in one step

```bash
dbt build
```

This is what you'll use day-to-day. For a one-model project it
collapses to the same effect as `dbt run && dbt test`, but
keeps you in the habit for when there are dependencies.

### Step 3 — Generate and serve the docs

```bash
dbt docs generate
dbt docs serve
```

The first command parses your project, runs introspection queries
against the warehouse to get column types, and writes
`target/manifest.json` + `target/catalog.json`. The second serves
those as a single-page app at `http://localhost:8080`.

Things to do in the docs site:

1. **Navigate the project tree** on the left. Click
   `stg_memphis__incidents`.
2. **Read the description and column-level descriptions.** This
   is what `_stg_models.yml` produced.
3. **Click the "View Lineage Graph" icon** (bottom right).
   You'll see `memphis.incidents` → `stg_memphis__incidents`.
   In Lesson 5 this graph will sprout marts; the docs site is
   how you'll keep oriented.
4. **Click a column.** dbt cross-references which tests apply to
   it. `incident_id` shows `not_null` and `unique`.

When you're done, `Ctrl-C` the serve process. Re-run
`dbt docs generate` whenever you change descriptions or add
models.

### Step 4 — Inspect a failed test's SQL (educational)

Even if all tests pass, the compiled SQL is in
`target/compiled/civic_pulse/models/staging/_stg_models.yml/`.
Each generic test compiles to its own .sql file. Open
`not_null_stg_memphis__incidents_incident_id.sql` — you'll see
the bare WHERE clause we walked through earlier.

This is how every test in the project works under the hood. Once
you've seen the pattern once, custom generic tests (a topic for
later) feel obvious.

---

## Further reading

- [Add tests to your models](https://docs.getdbt.com/docs/build/data-tests) — official intro.
- [Generic tests reference](https://docs.getdbt.com/reference/resource-properties/data-tests) — every built-in option.
- [Singular tests](https://docs.getdbt.com/docs/build/data-tests#singular-data-tests) — the one-off SQL pattern.
- [Document your project](https://docs.getdbt.com/docs/build/documentation) — descriptions, doc blocks, the rendered site.

---

## Done when…

- [ ] `dbt test` passes (or the failures are intentional — Memphis
      data sometimes has future-dated rows; if `assert_incident_date_not_future`
      fails, inspect the rows and decide whether to fix the staging
      model or accept the failure as informational).
- [ ] `dbt build` passes.
- [ ] You can articulate the difference between a generic and a
      singular test.
- [ ] You can locate the compiled SQL for any test in `target/compiled/`.
- [ ] The `dbt docs serve` lineage graph shows source → staging.

**Next:** [Lesson 5 — Marts & star schema](lesson-05-marts-and-star-schema.md).
With the staging contract locked in, we build the dimensional
models that BI tools will hit.
