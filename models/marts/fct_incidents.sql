-- models/marts/fct_incidents.sql
--
-- Incident fact table. Grain: one row per reported incident.
--
-- Lesson 6 refactor: the coalesce-based join is replaced with a
-- hash-equality join using the same surrogate-key macro the dims
-- use. Cleaner SQL, and guarantees the fact-side hash matches the
-- dim-side hash because they call the same macro.
--
-- Why is `incident_count` a column of all 1s? Two reasons:
--   1. It makes BI-tool SUM aggregations explicit. `SUM(incident_count)`
--      reads more clearly than `COUNT(*)` in a Looker/Tableau metric.
--   2. It makes the model future-proof: if MPD ever starts publishing
--      multiplicity, we replace the literal 1 with that column
--      without touching any downstream consumer.

{{ config(materialized='table') }}

with incidents as (

    select * from {{ ref('stg_memphis__incidents') }}

),

joined as (

    select
        i.incident_id,

        -- Date key as YYYYMMDD integer. Constructed from
        -- year/month/day primitives for DuckDB <> Snowflake portability.
        (year(i.offense_date)  * 10000
       + month(i.offense_date) * 100
       + day(i.offense_date))                       as date_key,

        -- Surrogate FKs computed inline. The macro produces the
        -- identical hash to what dim_location/dim_offense built;
        -- the join is one hash-equality comparison per dim instead
        -- of three coalesce-equality comparisons.
        {{ dbt_utils.generate_surrogate_key([
            'i.ward',
            'i.precinct',
            'i.council_district',
        ]) }} as location_key,

        {{ dbt_utils.generate_surrogate_key([
            'i.offense_category',
            'i.offense_description',
        ]) }} as offense_key,

        -- Attributes that don't roll up to a dim:
        i.offense_datetime,
        i.latitude,
        i.longitude,
        i.street_address,

        1::int                                      as incident_count

    from incidents i

)

select * from joined
