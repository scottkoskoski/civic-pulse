# Lesson 1 — Setup & First Run

> **Goal:** Stand up a working dbt project against a local DuckDB
> warehouse, and confirm the toolchain is healthy *before* you write
> a single model.
>
> **Time:** ~2 hours, mostly reading and tinkering.
>
> **You'll come away knowing:** what a dbt project is structurally,
> what a profile/target is and where it lives, the difference between
> dbt's "core" and an "adapter", and why our learning warehouse is
> DuckDB rather than Snowflake (yet).

---

## What problem are we solving?

dbt is a SQL compiler. You give it a folder full of `.sql` files and
some configuration; it figures out the dependencies between them,
compiles Jinja templates into pure SQL, and executes that SQL against
a warehouse. The hard part of "learning dbt" isn't the SQL — you
already know SQL. It's understanding *how dbt structures a project*:
where files live, how the CLI finds them, where credentials sit, and
how the compiler walks the graph.

This lesson installs nothing fancy. By the end you'll have:

1. A Python virtual environment with `dbt-core` and `dbt-duckdb`.
2. A `dbt_project.yml` that describes our (still empty) project.
3. A `~/.dbt/profiles.yml` that tells dbt how to connect to a local
   DuckDB file.
4. A green `dbt debug` proving the wiring works.

No models yet. No data yet. Just the skeleton.

---

## Concepts introduced

A precise glossary, in the order you'll encounter the terms below.
Future lessons will reference these; if anything feels fuzzy, this is
the spot to anchor it.

- **dbt project** — a directory containing a `dbt_project.yml` file
  plus the standard subfolders (`models/`, `seeds/`, `snapshots/`,
  `macros/`, `tests/`, `analyses/`). The CLI identifies "the
  project" by walking up from the current directory looking for
  `dbt_project.yml`. Everything else flows from that file.

- **dbt core** — the open-source Python package (`dbt-core`) that
  implements the compiler, the graph resolver, the macro engine, and
  the CLI. It does not, by itself, know how to talk to any warehouse.

- **adapter** — a separate package that teaches dbt-core a specific
  warehouse's SQL dialect and connection protocol. Examples:
  `dbt-duckdb`, `dbt-snowflake`, `dbt-postgres`, `dbt-bigquery`.
  Installing an adapter pulls dbt-core in as a transitive dependency,
  so you typically only `pip install dbt-duckdb`.

- **profile** — a named bundle of connection configurations defined
  in `~/.dbt/profiles.yml`. The `profile:` field in `dbt_project.yml`
  picks which one a given project uses. One machine can host many
  profiles; one profile can have many *targets*.

- **target** — a named environment within a profile. Typical setups
  have `dev`, `prod`. Ours will have `duckdb` (the local development
  target) and eventually `snowflake` (the capstone target). The
  active target is whatever the profile's `target:` key points at,
  overridable per-command with `dbt run --target snowflake`.

- **materialization** — *how* dbt builds a model into the warehouse:
  `view`, `table`, `incremental`, or `ephemeral`. We set defaults in
  `dbt_project.yml` today and individual models override them later.

- **`dbt debug`** — the diagnostic command. Loads your project,
  reads your profile, attempts to connect, and reports back. The
  first thing to run after any setup change.

---

## The build, narrated

This commit creates seven things. Walk through them in order; each
file's purpose makes more sense if you read the previous one first.

### 1. `.gitignore` — keep ephemera out of version control

```
target/
dbt_packages/
logs/
.venv/
*.duckdb
*.duckdb.wal
.env
profiles.yml
```

A few of these deserve commentary:

- **`target/`** is where dbt drops compiled SQL, the run results
  manifest, the documentation catalog, and other artifacts. It's
  deterministic build output — regenerate it any time with
  `dbt compile`. Never commit it.
- **`dbt_packages/`** is dbt's `node_modules` equivalent.
  `dbt deps` populates it from `packages.yml` (Lesson 6).
- **`*.duckdb`** is our actual warehouse data file. Treat it as
  *ephemeral* — the source of truth is the ingest script + dbt
  project, not the binary. Anyone cloning this repo regenerates
  it locally.
- **`profiles.yml`** at the repo root is excluded as a guard. Your
  real profile lives at `~/.dbt/profiles.yml`, but if you ever copy
  it into the working tree by accident, the ignore prevents a
  credential leak.
- **`.env`** is for environment variables (like the Socrata API
  token in Lesson 2). Excluded for the same reason.

### 2. `requirements.txt` — Python dependencies

```
dbt-core>=1.8,<2.0
dbt-duckdb>=1.8,<2.0
# dbt-snowflake>=1.8,<2.0     # uncomment in Lesson 8
requests>=2.31,<3.0
python-dotenv>=1.0,<2.0
```

Two small choices baked in here:

- We **pin to a loose range** rather than exact versions. On a
  learning project, exact pins like `==1.8.3` lock you out of patch
  releases that fix real bugs. The upper bound on the major version
  prevents a future `2.0` from breaking your setup unattended.
- `dbt-snowflake` is **commented out**, not absent. Installing it
  in Lesson 1 would pull in Snowflake adapter dependencies you
  don't need yet, slowing the install and adding noise to the
  Python environment. The commented line is a forward-pointer.

### 3. `dbt_project.yml` — the project's identity card

The key directives:

```yaml
name: 'civic_pulse'
profile: 'civic_pulse'

model-paths: ["models"]
seed-paths: ["seeds"]
# ... and so on for the other folders

models:
  civic_pulse:
    staging:
      +materialized: view
      +schema: staging
    marts:
      +materialized: table
      +schema: marts
```

Two things to internalize:

**`profile:` is a string lookup**, not a path. dbt reads
`~/.dbt/profiles.yml`, looks for a top-level key matching this
string (`civic_pulse`), and uses everything underneath. The name
collision between project and profile is conventional; if you ever
have multiple projects sharing a warehouse, give them distinct
profile names.

**The `models:` block is hierarchical configuration.** `civic_pulse`
must match the project `name:` above. Inside it, `staging` and
`marts` correspond to subfolders under `models/`. Every key prefixed
with `+` is a configuration directive that applies to all models in
that folder (and any deeper subfolders). Models override these
defaults individually with `{{ config(...) }}` blocks at the top of
their `.sql` files.

The default-materialization choice — `view` for staging, `table` for
marts — is one of the most important decisions in a dbt project,
and it's documented in `docs/decisions.md`. Short version: staging
is cheap rename/cast logic that we want recomputed on every query
(a view is just a stored query, zero storage cost), while marts are
the analytical truth that BI tools will hammer with thousands of
reads, so materializing them as physical tables avoids re-running
the upstream SQL every time.

### 4. `profiles.yml.example` — credential template

The real `profiles.yml` lives at `~/.dbt/profiles.yml`. The committed
file is a *template* you copy and edit:

```yaml
civic_pulse:
  target: duckdb
  outputs:
    duckdb:
      type: duckdb
      path: /ABSOLUTE/PATH/TO/civic-pulse/civic_pulse.duckdb
      schema: main
      threads: 4
    # snowflake:    <-- commented stub for Lesson 8
```

The DuckDB adapter wants an *absolute* path to a `.duckdb` file. If
the file doesn't exist, DuckDB creates it on first connect. So
"setting up the warehouse" is literally one line of YAML.

`threads: 4` controls dbt's build parallelism. DuckDB is in-process
and serializes writes, so threads >1 mostly help with compile time
rather than execution. We'll leave 4 in place; you won't notice the
difference on a project this size.

### 5. `packages.yml` — empty by design

```yaml
packages: []
```

We commit this empty so it's part of the project's visible
structure. Lesson 6 will populate it with `dbt-labs/dbt_utils`.
Having the file present from day one prevents a surprise "what's
this new yaml file?" moment later.

### 6. The directory skeleton

`models/staging/`, `models/marts/`, `seeds/`, `snapshots/`,
`macros/`, `tests/`, `analyses/`, `data-engineering/ingest/`.

Each contains a `.gitkeep` placeholder so git tracks the empty
directory. dbt cheerfully runs against empty folders; the structure
is there to give later lessons a place to land.

### 7. `docs/decisions.md`

A flat, one-line-per-decision log. The lesson chapters explain
*why*; this file gives you a one-screen scan of *what was decided*.
If you forget six weeks from now why staging is materialized as a
view, that's the file to grep.

---

## Decisions & tradeoffs

The big ones are in `docs/decisions.md`. Some additional context on
the choices most likely to confuse a newcomer:

### Why DuckDB first?

The default dbt tutorial uses BigQuery, Snowflake, or Postgres. Each
requires you to either sign up for a cloud account or run a local
server. DuckDB is:

- **Embedded** — no server, no port, no daemon. A single binary
  and a single file.
- **Free** — no credits, no trial expiration. Hammer it as much as
  you want.
- **Fast on small data** — the whole Memphis crime dataset fits in
  RAM and queries in milliseconds. Iteration loops feel instant.
- **Adapter-supported** — the `dbt-duckdb` adapter is mature and
  actively maintained.

The catch: DuckDB's SQL dialect is *not* identical to Snowflake's.
Some patterns that work in DuckDB will need adjustment in Lesson 8.
We'll call those out as we encounter them. The tradeoff is worth it
because we get six lessons of friction-free practice before paying
the Snowflake-specific tax.

### Why not `dbt init`?

The official getting-started flow has you run `dbt init my_project`,
which scaffolds a project with two example models
(`my_first_dbt_model.sql`, `my_second_dbt_model.sql`) plus a sample
`schema.yml`. They're meant as throwaway demos.

We skipped `dbt init` and hand-shaped the project instead. Three
reasons:

1. The example models would be deleted in Lesson 2 anyway. Better
   to never have them than to start with code we don't believe in.
2. `dbt init` writes a `profiles.yml` to `~/.dbt/` interactively,
   asking questions during setup. Our `profiles.yml.example` is more
   transparent: you see exactly what's being configured.
3. Each commit in this tutorial corresponds to one lesson's worth
   of work. If `dbt init` had run, the Lesson 1 diff would include
   a bunch of code we'd immediately delete in Lesson 2. Honesty of
   the git history matters when you're using it as a study aid.

### Why have a `packages.yml` if it's empty?

It's a forward-pointer. When you scan the repo and see
`packages.yml`, you know dbt packages are a thing this project will
eventually use. Adding the file in Lesson 6 would be a small
distraction from that lesson's actual point (custom macros).

### Why not commit `~/.dbt/profiles.yml` to the repo for convenience?

In a real deployment, `profiles.yml` holds the password or key for
your production warehouse. The dbt project itself is shareable
(public repo, open source); the connection material is not. Keeping
profiles outside the repo from day one means there's no migration
later when you start using real credentials.

For this learning project, you could in principle commit a
DuckDB-only profile to the repo and not lose anything. But it
reinforces a bad habit. We're going to do it the right way from
Lesson 1.

---

## Run it

```bash
# 1. Create and activate a Python virtual environment
cd /path/to/civic-pulse
python -m venv .venv
source .venv/bin/activate   # (Windows: .venv\Scripts\activate)

# 2. Install dependencies
pip install -r requirements.txt

# 3. Set up the dbt profile
mkdir -p ~/.dbt
cp profiles.yml.example ~/.dbt/profiles.yml
# Then edit ~/.dbt/profiles.yml and replace the placeholder
# /ABSOLUTE/PATH/TO/civic-pulse/civic_pulse.duckdb with the
# real absolute path on your machine.

# 4. Diagnose
dbt debug
```

Expected `dbt debug` output (trimmed):

```
Running with dbt=1.x.x
dbt version: ...
python version: ...
python path: .../.venv/bin/python
Configuration:
  profiles.yml file [OK found and valid]
  dbt_project.yml file [OK found and valid]
Required dependencies:
 - git [OK found]
Connection:
  ...
  Connection test: [OK connection ok]

All checks passed!
```

If you see `[ERROR ...]` on any line, the message tells you which
file or field to fix. The two most common gotchas:

- **`profiles.yml file [ERROR not found]`** — the file is at the
  wrong path. `dbt debug` prints where it looked.
- **`Connection: ... [ERROR ...]`** — the DuckDB `path:` is wrong
  or points to a non-writable location.

Once `dbt debug` is green, prove the project itself parses:

```bash
dbt parse
```

`dbt parse` walks your project files and builds the internal
manifest *without* hitting the warehouse. On an empty project it
should return in under a second.

You will *not* run `dbt run` yet — we have no models. That comes
in Lesson 3.

---

## Further reading

Linked sparingly, all from the official docs:

- [About dbt projects](https://docs.getdbt.com/docs/build/projects) — the conceptual overview of `dbt_project.yml`.
- [Connect to DuckDB](https://docs.getdbt.com/docs/core/connect-data-platform/duckdb-setup) — the adapter reference.
- [Profiles.yml](https://docs.getdbt.com/docs/core/connect-data-platform/profiles.yml) — the full schema for profiles.
- [Materializations](https://docs.getdbt.com/docs/build/materializations) — we'll revisit this in Lesson 3.

---

## Done when…

- [ ] `dbt debug` exits with `All checks passed!`
- [ ] `dbt parse` runs without errors
- [ ] You can articulate, in one sentence each:
  - what `dbt_project.yml` does
  - what `profiles.yml` does
  - the difference between a profile and a target
  - why staging defaults to `view` and marts default to `table`

**Next:** [Lesson 2 — Ingest & Sources](lesson-02-ingest-and-sources.md). We'll
pull real Memphis crime data into the local DuckDB warehouse with a
small Python script, then teach dbt that the raw table exists by
declaring it as a *source*.
