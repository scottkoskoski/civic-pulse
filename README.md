# civic-pulse

A small, hands-on **dbt + Snowflake learning project** built around real
Memphis crime data. The repository doubles as a **built tutorial**:
every model, macro, snapshot, and config file is accompanied by a
chapter in [`docs/`](docs/) that explains what it does, why it's
shaped that way, and what alternatives were rejected.

You'll learn dbt fundamentals against a **local DuckDB warehouse**
first (no Snowflake credentials needed for Lessons 1-7), then port
the same project to **Snowflake** as a capstone. The point isn't a
production pipeline — it's the smallest project that exercises the
core dbt concepts cleanly, at a pace of ~2-3 hours per week over
eight weeks.

---

## Table of contents

- [What you'll learn](#what-youll-learn)
- [Curriculum](#curriculum)
- [How the tutorial is structured](#how-the-tutorial-is-structured)
- [Prerequisites](#prerequisites)
- [Quickstart](#quickstart)
- [Project structure](#project-structure)
- [Tech stack](#tech-stack)
- [Data source](#data-source)
- [Design decisions](#design-decisions)
- [What's intentionally excluded](#whats-intentionally-excluded)
- [Beyond this project](#beyond-this-project)

---

## What you'll learn

By the end of Lesson 8 you'll be comfortable with:

- **Project anatomy** — `dbt_project.yml`, `profiles.yml`, targets,
  adapters, and the relationship between them.
- **Sources and models** — declaring raw tables via
  `_sources.yml`, writing staging models with the canonical
  `source → renamed → final` CTE structure, and using `ref()` to
  build a dependency graph.
- **Materializations** — when to use `view`, `table`,
  `incremental`, and `ephemeral`, and what each compiles to.
- **Testing** — generic tests (`not_null`, `unique`,
  `accepted_values`, `relationships`), singular tests, and the
  test-before-marts discipline.
- **Documentation** — column-level descriptions, `dbt docs
  generate`, and using the rendered lineage graph as a
  navigation tool.
- **Dimensional modeling** — building a Kimball-style star schema
  with three conformed dimensions, surrogate keys (with correct
  NULL handling), a checked-in `dim_date` seed, and
  `relationships` tests that prove no fact-table foreign key
  orphans.
- **Jinja and macros** — writing custom macros, using
  `dbt_utils`, and installing packages via `packages.yml` and
  `dbt deps`.
- **Incremental models and snapshots** — `is_incremental()`,
  `unique_key`, high-water-mark filters with a lateness budget,
  and SCD-2 history via `strategy='check'` snapshots.
- **Snowflake fundamentals** — trial-account setup, warehouses,
  databases, schemas, internal stages, and `COPY INTO` with
  `INFER_SCHEMA` — enough to run the same project against a
  managed cloud warehouse.

---

## Curriculum

Eight lesson chapters, each self-contained. Follow them in order —
each chapter builds on the previous one.

| # | Chapter | Concepts introduced |
|---|---------|--------------------|
| 1 | [Setup & first run](docs/lesson-01-setup-and-first-run.md) | dbt project anatomy, profiles, adapters, virtual envs |
| 2 | [Ingest & sources](docs/lesson-02-ingest-and-sources.md) | Python EL, Socrata SODA API, `{{ source() }}` |
| 3 | [First staging model](docs/lesson-03-staging-and-materializations.md) | `{{ ref() }}`, view vs. table, CTE-first structure, `try_cast` |
| 4 | [Tests & docs](docs/lesson-04-tests-and-docs.md) | generic + singular tests, `schema.yml`, `dbt docs serve` |
| 5 | [Marts & star schema](docs/lesson-05-marts-and-star-schema.md) | Kimball star schema, seeds, md5 surrogate keys, `relationships` |
| 6 | [Jinja, macros, packages](docs/lesson-06-jinja-macros-packages.md) | `dbt deps`, custom macros, `dbt_utils.generate_surrogate_key` |
| 7 | [Incremental & snapshots](docs/lesson-07-incremental-and-snapshots.md) | `is_incremental()`, `{{ this }}`, SCD-2 with `check` strategy |
| 8 | [Port to Snowflake](docs/lesson-08-port-to-snowflake.md) | Snowflake trial setup, internal stages, `COPY INTO`, adapter portability |

The [`docs/decisions.md`](docs/decisions.md) file is a flat,
one-line-per-decision log of every non-trivial choice made across
the tutorial — useful as a reference once you've finished the
chapters and want to remember *why* something is the way it is.

---

## How the tutorial is structured

Each chapter follows the same template so you always know where
to look for a given kind of information:

1. **Goal / time / outcomes** at the top of every chapter.
2. **What problem are we solving?** — the pedagogical motivation
   for the lesson.
3. **Concepts introduced** — a precise glossary of the new terms
   the chapter uses.
4. **The build, narrated** — code excerpts with line-by-line
   explanation of the non-obvious decisions.
5. **Decisions & tradeoffs** — a "we picked X. We considered Y
   and Z. Here's why X won." section.
6. **Run it** — exact commands, expected output, what to look
   for. Includes `Done when…` checklists you can tick off.
7. **Further reading** — links into the official dbt docs.

Every lesson corresponds to exactly one git commit on the
`claude/dbt-snowflake-learning-project-*` branch, so you can also
learn by walking the history with `git log --oneline` and running
`git show <sha>` on each commit.

---

## Prerequisites

- **Python 3.10+** with `venv` support.
- **Solid SQL** — you should be comfortable with joins, CTEs,
  window functions, and aggregation. The tutorial explains dbt
  concepts, not SQL basics.
- **Comfortable with the command line** — `bash`/`zsh` on
  macOS/Linux, or WSL on Windows. Windows-native
  `cmd`/PowerShell works but a few commands need adjustment.
- **Git**, for cloning the repo and walking the commit history.
- **Optional but recommended:** the standalone
  [DuckDB CLI](https://duckdb.org/docs/installation/) for
  ad-hoc queries against the warehouse.
- **Lesson 8 only:** a free
  [Snowflake trial account](https://signup.snowflake.com/) and
  [SnowSQL](https://docs.snowflake.com/en/user-guide/snowsql).

---

## Quickstart

```bash
# 1. Clone and enter
git clone https://github.com/scottkoskoski/civic-pulse.git
cd civic-pulse

# 2. Create a Python virtual environment and install dbt
python -m venv .venv
source .venv/bin/activate            # Windows: .venv\Scripts\activate
pip install -r requirements.txt

# 3. Configure your dbt profile
mkdir -p ~/.dbt
cp profiles.yml.example ~/.dbt/profiles.yml
#   Then edit ~/.dbt/profiles.yml and replace the placeholder
#   /ABSOLUTE/PATH/TO/civic-pulse/civic_pulse.duckdb with the
#   real absolute path on your machine.

# 4. Configure the Socrata data source (Lesson 2 onward)
cp .env.example .env
#   Then edit .env and set SOCRATA_DATASET_ID.
#   See docs/lesson-02-ingest-and-sources.md for how to find it.

# 5. Verify
dbt debug        # should print "All checks passed!"
dbt parse        # should succeed even with zero models

# 6. Open the first lesson
$EDITOR docs/lesson-01-setup-and-first-run.md
```

From there, work chapter by chapter. Each chapter's `Run it`
section tells you exactly which commands to invoke.

---

## Project structure

```
civic-pulse/
├── README.md                          You are here.
├── requirements.txt                   Python deps (dbt-duckdb, dbt-snowflake, requests, python-dotenv)
├── dbt_project.yml                    dbt project config
├── profiles.yml.example               Template for ~/.dbt/profiles.yml (DuckDB + Snowflake targets)
├── packages.yml                       dbt package deps (dbt_utils)
├── .env.example                       Template for .env (SOCRATA_DATASET_ID, etc.)
│
├── docs/                              The tutorial
│   ├── decisions.md                   Running rationale log
│   ├── lesson-01-setup-and-first-run.md
│   ├── lesson-02-ingest-and-sources.md
│   ├── lesson-03-staging-and-materializations.md
│   ├── lesson-04-tests-and-docs.md
│   ├── lesson-05-marts-and-star-schema.md
│   ├── lesson-06-jinja-macros-packages.md
│   ├── lesson-07-incremental-and-snapshots.md
│   └── lesson-08-port-to-snowflake.md
│
├── data-engineering/
│   ├── config/__init__.py             (project stub, kept intact)
│   ├── ingest/
│   │   └── load_memphis_crime.py      Socrata → DuckDB loader (Lesson 2)
│   └── snowflake/
│       ├── 01_setup.sql               Snowflake account setup (Lesson 8)
│       └── 02_copy_raw.sql            Parquet → Snowflake COPY INTO
│
├── models/
│   ├── staging/
│   │   ├── _sources.yml               Source declaration
│   │   ├── _stg_models.yml            Descriptions + generic tests
│   │   └── stg_memphis__incidents.sql Staging view
│   └── marts/
│       ├── _marts_models.yml          Descriptions + relationships tests
│       ├── dim_location.sql
│       ├── dim_offense.sql
│       └── fct_incidents.sql          Incremental (Lesson 7)
│
├── seeds/
│   └── dim_date.csv                   Calendar dim (2015-2030)
│
├── snapshots/
│   └── snap_offense_categories.sql    SCD-2 history
│
├── macros/
│   └── clean_text.sql                 Custom text-normalization macro
│
├── tests/
│   └── assert_incident_date_not_future.sql   Singular data test
│
└── analyses/                          (empty; scratch space for ad-hoc queries)
```

---

## Tech stack

- **[dbt-core](https://docs.getdbt.com/)** — the SQL compiler and
  orchestrator this project revolves around.
- **[dbt-duckdb](https://github.com/duckdb/dbt-duckdb)** — the
  DuckDB adapter, used as the local warehouse for Lessons 1-7.
- **[dbt-snowflake](https://docs.getdbt.com/docs/core/connect-data-platform/snowflake-setup)**
  — the Snowflake adapter, activated in Lesson 8.
- **[DuckDB](https://duckdb.org/)** — an embedded columnar database.
  Single file, zero setup, fast.
- **[Snowflake](https://www.snowflake.com/)** — a managed cloud
  data warehouse. The trial account's $400 credit is more than
  enough for this project.
- **Python** with `requests` and `python-dotenv` for the one-shot
  ingest script.
- **[`dbt_utils`](https://github.com/dbt-labs/dbt-utils)** — the
  canonical dbt utility-macro package. Adopted in Lesson 6.

No orchestrator, no CI, no dbt Cloud. The dbt CLI from your
terminal is enough for the entire project.

---

## Data source

[Memphis Police Department incident data](https://data.memphistn.gov)
via the [Socrata Open Data API](https://dev.socrata.com/) (SODA).
Public, well-documented, and just messy enough to give the staging
layer real work to do:

- **Realistic quirks** — lat/lng arrive as strings, some columns
  are inconsistently cased, `(0, 0)` sentinels stand in for
  "unknown location," and offense categories occasionally get
  reclassified upstream (which is why Lesson 7's snapshot exists).
- **Meaningful shape** — every incident has a date, a location,
  and a category, so it naturally supports a small star schema
  without contortions.
- **Reasonable size** — around 100k-500k rows depending on the
  dataset version, small enough to iterate on quickly but large
  enough that incremental materialization has real impact.

The 4-by-4 dataset id changes on Memphis's data-portal
republishes, so we don't hardcode it. [Lesson 2](docs/lesson-02-ingest-and-sources.md#step-1--find-the-socrata-dataset-id)
walks through the lookup step.

---

## Design decisions

A few high-level choices worth surfacing so newcomers know what
to expect. The full rationale for each is in
[`docs/decisions.md`](docs/decisions.md) and the relevant lesson
chapters.

- **DuckDB first, Snowflake last.** Learn dbt cleanly on a
  zero-friction local warehouse before touching a cloud account.
  The Lesson 8 port then demonstrates the payoff — the same
  project builds against both targets with no model edits.
- **Extract/Load stays out of dbt.** A small Python script owns
  ingestion. dbt owns transformation. Mixing them conflates
  failure modes and makes debugging harder.
- **End-to-end runnable by Lesson 3.** Staging is built before
  tests, marts, macros, or snapshots so there's a "the pipeline
  works" milestone early enough to sustain momentum.
- **Tests come before marts (Lesson 4 before Lesson 5).** Marts
  inherit staging assumptions. Locking the staging contract first
  means downstream failures are unambiguous.
- **Portability decisions baked in from day one.** `try_cast`
  over dialect-specific alternatives, `year/month/day` primitives
  over `strftime`, `dbt_utils.generate_surrogate_key` over
  hand-rolled hashes. These pay off in Lesson 8 when the project
  ports to Snowflake without SQL edits.

---

## What's intentionally excluded

Deferred to keep the tutorial focused. Every one of these is a
worthwhile topic — just not the fastest path from zero to
practical fluency.

| Excluded | Why deferred |
|---|---|
| dbt Cloud | Cost + abstracts away the CLI fundamentals the tutorial focuses on. |
| Airflow / Dagster / Prefect | Orchestration is a separate skill. `cron` or manual runs suffice at this scale. |
| CI/CD (GitHub Actions, Slim CI) | Adds YAML + secrets management overhead. Revisit once you have a multi-contributor project. |
| dbt semantic layer / MetricFlow | Conceptually heavy; depends on solid mart modeling. |
| Exposures, groups, contracts | Shine in team settings; low value for solo learning. |
| Python models | Adapter-specific (Snowpark vs. local Python). Master SQL models first. |
| Unit tests (dbt 1.8+) | Generic + singular data tests cover the core concepts. |
| dbt Mesh, custom materializations | Advanced patterns; way out of scope. |
| Elementary / re_data / Great Expectations | Built-in tests + `dbt_utils` cover ~90% of a beginner's needs. |
| Production Snowflake hardening (RBAC matrices, network policies) | Lesson 8 keeps Snowflake to a "hello world" scope. |

---

## Beyond this project

Directions to explore once the fundamentals feel automatic
(covered briefly at the end of [Lesson 8](docs/lesson-08-port-to-snowflake.md#beyond-this-project)):

- **dbt Cloud** — a managed dbt scheduler with a built-in IDE, CI
  integration, and a hosted docs site.
- **Orchestration** — Airflow / Dagster / Prefect for scheduling
  and chaining `dbt build` with non-dbt steps.
- **CI/CD** — GitHub Actions running `dbt build --target ci` on
  every PR. dbt's slim CI feature only builds what changed.
- **Semantic layer** — MetricFlow definitions expose business
  logic to BI tools without every tool reinventing it.
- **Snowflake-specific features** — zero-copy clones, time travel,
  dynamic tables, streams + tasks for streaming ingestion.

None of these are required to be productive with dbt. They're the
next 10% once the fundamentals from this tutorial are second
nature.
