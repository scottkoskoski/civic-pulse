-- data-engineering/snowflake/02_copy_raw.sql
--
-- Loads the local Parquet export into raw.incidents on Snowflake.
-- Run AFTER you've:
--   1. Exported DuckDB raw.incidents to a Parquet file
--      (see docs/lesson-08-port-to-snowflake.md for the one-liner).
--   2. Uploaded the file to the internal stage via SnowSQL:
--          PUT file:///abs/path/to/incidents.parquet @raw.parquet_stage;
--
-- Idempotent: drops + recreates the table on every run.

use database civic_pulse;
use schema raw;

-- A named file format object that infer_schema and COPY INTO can
-- reference. Putting it in the raw schema co-locates it with the
-- stage.
create or replace file format raw.parquet_format
  type = 'parquet';

-- Build the table from the Parquet's embedded schema. Saves us
-- from hand-typing 20+ column definitions; Snowflake reads the
-- Parquet metadata and produces a CREATE TABLE statement for us.
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

-- COPY the data into the freshly-created table.
-- match_by_column_name = 'case_insensitive' lets Snowflake pair
-- Parquet columns with table columns by name regardless of case.
copy into raw.incidents
  from @raw.parquet_stage
  file_format = (format_name = 'raw.parquet_format')
  match_by_column_name = 'case_insensitive'
  on_error = 'continue';

-- Sanity check.
select count(*) as row_count from raw.incidents;
select * from raw.incidents limit 5;
