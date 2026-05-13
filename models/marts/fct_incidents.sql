-- models/marts/fct_incidents.sql
--
-- Incident fact table. Grain: one row per reported incident.
-- Equivalent to staging.stg_memphis__incidents in row count, but
-- structured for analytical query: every dimensional attribute is
-- a foreign key, leaving only incident-level measures and the
-- handful of attributes (lat/lng, address) that don't roll up to
-- a dimension.
--
-- Materialization: table (folder default). Lesson 7 will convert
-- this to an incremental table so daily reloads don't reprocess
-- the entire history.
--
-- Why is `incident_count` a column of all 1s? Two reasons:
--   1. It makes BI-tool SUM aggregations explicit. `SUM(incident_count)`
--      reads more clearly than `COUNT(*)` in a Looker/Tableau metric.
--   2. It makes the model future-proof: if MPD ever starts publishing
--      multiplicity (e.g., "this incident involved 3 victims"), we
--      replace the literal 1 with that column without touching any
--      downstream consumer.

{{ config(materialized='table') }}

with incidents as (

    select * from {{ ref('stg_memphis__incidents') }}

),

location as (

    select * from {{ ref('dim_location') }}

),

offense as (

    select * from {{ ref('dim_offense') }}

),

joined as (

    select
        -- Degenerate dimension: the natural key from the source
        -- system flows through as a column on the fact. Not all
        -- columns need their own dim; this one is granular enough
        -- (one value per row) that wrapping it would be silly.
        i.incident_id,

        -- Date key as YYYYMMDD integer, joinable to dim_date.date_key.
        -- We construct it from y/m/d primitives instead of strftime
        -- because year()/month()/day() are portable across DuckDB and
        -- Snowflake. strftime is DuckDB-specific.
        (year(i.offense_date)  * 10000
       + month(i.offense_date) * 100
       + day(i.offense_date))                       as date_key,

        -- Foreign keys to the conformed dimensions.
        l.location_key,
        o.offense_key,

        -- Attributes that don't roll up to a dim:
        i.offense_datetime,
        i.latitude,
        i.longitude,
        i.street_address,

        -- Measure column. See the docstring above for why this
        -- is a literal 1 rather than COUNT(*).
        1::int                                      as incident_count

    from incidents i
    -- Coalesce-based join: matches the NULL-sentinel pattern used
    -- to build the dim's surrogate key. Every distinct combination
    -- in staging produced a dim row, so this join never orphans —
    -- the relationships tests in _marts_models.yml prove it.
    left join location l
      on coalesce(i.ward, '__null__')              = coalesce(l.ward, '__null__')
     and coalesce(i.precinct, '__null__')          = coalesce(l.precinct, '__null__')
     and coalesce(i.council_district, '__null__')  = coalesce(l.council_district, '__null__')
    left join offense o
      on coalesce(i.offense_category, '__null__')   = coalesce(o.offense_category, '__null__')
     and coalesce(i.offense_description, '__null__')= coalesce(o.offense_description, '__null__')

)

select * from joined
