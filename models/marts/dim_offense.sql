-- models/marts/dim_offense.sql
--
-- Offense dimension: one row per distinct (category, description)
-- combination observed in staging.
--
-- Lesson 6 refactor: hand-rolled md5 replaced with
-- dbt_utils.generate_surrogate_key, matching the dim_location and
-- fct_incidents pattern.

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
        {{ dbt_utils.generate_surrogate_key([
            'offense_category',
            'offense_description',
        ]) }} as offense_key,
        offense_category,
        offense_description
    from distinct_offenses

)

select * from with_key
