-- models/marts/dim_location.sql
--
-- Location dimension: one row per distinct combination of ward,
-- precinct, and council district observed in the staging layer.
--
-- Grain: (ward, precinct, council_district). About 50-100 rows for
-- Memphis depending on how MPD codes administrative boundaries.
--
-- Lesson 6 refactor: hand-rolled `md5(coalesce(...) || '|' || ...)`
-- is replaced with dbt_utils.generate_surrogate_key. Same compiled
-- SQL (it expands to coalesce + md5 internally), but centralized:
-- the fact table now uses the same macro, eliminating drift risk
-- between dim and fact hashing logic.

{{ config(materialized='table') }}

with incidents as (

    select * from {{ ref('stg_memphis__incidents') }}

),

distinct_locations as (

    select distinct
        ward,
        precinct,
        council_district
    from incidents

),

with_key as (

    select
        {{ dbt_utils.generate_surrogate_key([
            'ward',
            'precinct',
            'council_district',
        ]) }} as location_key,
        ward,
        precinct,
        council_district
    from distinct_locations

)

select * from with_key
