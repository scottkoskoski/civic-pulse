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
