-- models/marts/dim_location.sql
--
-- Location dimension: one row per distinct combination of ward,
-- precinct, and council district observed in the staging layer.
--
-- Grain: (ward, precinct, council_district). About 50-100 rows for
-- Memphis depending on how MPD codes administrative boundaries.
--
-- Surrogate key: md5 hash over the natural-key columns with a NULL
-- sentinel substitution. Lesson 6 replaces this hand-rolled hash
-- with dbt_utils.generate_surrogate_key, which handles the same
-- concern but uniformly across warehouses.
--
-- Why no lat/lng on this dim? Those are *attributes of the incident*,
-- not of the administrative location. They live on fct_incidents.
--
-- Materialization: table (default for marts per dbt_project.yml).
-- BI tools will join this dim millions of times across dashboard
-- sessions; pre-materializing the join keys is worth the storage.

{{ config(materialized='table') }}

with incidents as (

    select * from {{ ref('stg_memphis__incidents') }}

),

distinct_locations as (

    -- DISTINCT over the natural key collapses 100k incident rows
    -- down to the ~100 location combinations that actually appear
    -- in the data. We deliberately keep the all-NULL row: it
    -- represents incidents reported without an administrative
    -- location, which is a real state of the world we want
    -- queryable.
    select distinct
        ward,
        precinct,
        council_district
    from incidents

),

with_key as (

    select
        -- A NULL sentinel substituted via coalesce means the hash
        -- is stable across rebuilds even when columns are NULL.
        -- Without coalesce, md5(NULL || '|' || ...) would be NULL,
        -- defeating the surrogate-key purpose.
        md5(
            coalesce(ward, '__null__')             || '|' ||
            coalesce(precinct, '__null__')         || '|' ||
            coalesce(council_district, '__null__')
        ) as location_key,
        ward,
        precinct,
        council_district
    from distinct_locations

)

select * from with_key
