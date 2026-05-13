-- models/staging/stg_memphis__incidents.sql
--
-- Staging model: one row per Memphis Police Department incident,
-- with column names normalized and types coerced. This is the only
-- model in the project that touches raw.incidents directly; every
-- downstream model goes through this view.
--
-- Materialization: view (set as the staging-folder default in
-- dbt_project.yml). Views are zero-storage and always fresh, which
-- is what we want for a thin rename/cast layer.
--
-- Lesson 6 refactor: the text-normalization pattern
-- `nullif(lower(trim(col)), '')` is now `{{ clean_text('col') }}`.
-- Identical compiled SQL, but the intent is named.
--
-- A NOTE ON COLUMN NAMES:
-- Socrata's actual column names for the Memphis incidents dataset
-- may differ from those assumed below. Run `describe raw.incidents`
-- in the DuckDB CLI after Lesson 2's loader, then adjust the
-- source-side names on the right-hand side of each `as` clause to
-- match what you actually have.

{{ config(materialized='view') }}

with source as (

    select * from {{ source('memphis', 'incidents') }}

),

renamed as (

    select
        -- ---------- Identifiers ----------
        incident_number                                     as incident_id,

        -- ---------- Temporal ----------
        try_cast(offense_date as date)                      as offense_date,
        try_cast(offense_date as timestamp)                 as offense_datetime,

        -- ---------- Offense classification ----------
        {{ clean_text('offense_description') }}             as offense_description,
        {{ clean_text('offense_category')    }}             as offense_category,

        -- ---------- Geography ----------
        case
            when try_cast(latitude  as double) = 0 then null
            else try_cast(latitude  as double)
        end                                                 as latitude,
        case
            when try_cast(longitude as double) = 0 then null
            else try_cast(longitude as double)
        end                                                 as longitude,

        {{ clean_text('street_address') }}                  as street_address,
        {{ clean_text('ward')           }}                  as ward,
        {{ clean_text('precinct')       }}                  as precinct,
        {{ clean_text('council_district') }}                as council_district

    from source

)

select * from renamed
