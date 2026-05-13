-- data-engineering/snowflake/01_setup.sql
--
-- One-time Snowflake account setup. Run this via the Snowflake web
-- console (Worksheets) or SnowSQL after creating your trial account.
-- Idempotent: re-running is safe.
--
-- After this finishes, you can configure ~/.dbt/profiles.yml with
-- the Snowflake target and run `dbt build --target snowflake`.

-- A dedicated database keeps the project's objects separate from
-- whatever else lives in your trial account.
create database if not exists civic_pulse;

-- A small warehouse is plenty for the project's scale. Auto-suspend
-- and auto-resume save credits when you're not running queries.
create warehouse if not exists compute_wh
  with warehouse_size = 'XSMALL'
  auto_suspend = 60
  auto_resume = true
  initially_suspended = true;

use database civic_pulse;

-- Mirror the schema layout from DuckDB. dbt will create model
-- objects in staging/marts/snapshots; the raw schema holds the
-- table we COPY INTO from the local export.
create schema if not exists raw;
create schema if not exists staging;
create schema if not exists marts;
create schema if not exists snapshots;

-- An internal stage holds the Parquet file we'll PUT before COPY.
-- An internal stage is account-managed object storage; you don't
-- need a separate S3 bucket.
create stage if not exists raw.parquet_stage
  file_format = (type = 'parquet')
  comment = 'Local Parquet uploads prior to COPY INTO raw tables.';

-- Confirm the setup ran. The output should list all four schemas.
show schemas in database civic_pulse;
