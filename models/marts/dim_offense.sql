-- models/marts/dim_offense.sql
--
-- Offense dimension: one row per distinct (category, description)
-- combination observed in staging.
--
-- Grain: (offense_category, offense_description). Expected ~100-300
-- rows depending on Memphis's offense vocabulary.
--
-- Surrogate key: md5 over the natural-key columns with NULL
-- sentinels. Same pattern as dim_location.
--
-- Note for Lesson 7: this dimension is the snapshot target. We'll
-- track changes to offense_description over time using a snapshot
-- file that uses the `check_cols` strategy, since description
-- wording occasionally gets updated upstream.

{{ config(materialized='table') }}

with incidents as (

    select * from {{ ref('stg_memphis__incidents') }}

),

distinct_offenses as (

    select distinct
        offense_category,
        offense_description
    from incidents

),

with_key as (

    select
        md5(
            coalesce(offense_category, '__null__')    || '|' ||
            coalesce(offense_description, '__null__')
        ) as offense_key,
        offense_category,
        offense_description
    from distinct_offenses

)

select * from with_key
