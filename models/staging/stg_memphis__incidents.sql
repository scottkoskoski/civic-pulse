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
-- A NOTE ON COLUMN NAMES:
-- Socrata's actual column names for the Memphis incidents dataset
-- may differ from those assumed below — datasets get republished
-- with renamed fields. Run `describe raw.incidents` in the DuckDB
-- CLI after Lesson 2's loader, then adjust the source-side column
-- names on the right-hand side of each `as` clause to match what
-- you actually have. The model's *target* column names (the ones
-- after `as`) should stay as written so downstream models keep
-- working.

{{ config(materialized='view') }}

with source as (

    select * from {{ source('memphis', 'incidents') }}

),

renamed as (

    select
        -- ---------- Identifiers ----------
        -- The natural key for each incident. Adjust the source name
        -- if your dataset uses crime_id, offense_id, case_number, etc.
        incident_number                                     as incident_id,

        -- ---------- Temporal ----------
        -- try_cast (DuckDB) returns NULL on bad inputs instead of
        -- failing the build, which matters because Socrata sometimes
        -- returns malformed dates from historical records. We surface
        -- those NULLs as a test failure in Lesson 4 instead of a
        -- pipeline crash here.
        try_cast(offense_date as date)                      as offense_date,
        try_cast(offense_date as timestamp)                 as offense_datetime,

        -- ---------- Offense classification ----------
        -- lower(trim(...)) is a cheap normalizer: Socrata mixes
        -- "ASSAULT", "Assault", and "assault" across rows. We pick
        -- lowercase as canonical and strip leading/trailing whitespace.
        nullif(lower(trim(offense_description)), '')        as offense_description,
        nullif(lower(trim(offense_category)), '')           as offense_category,

        -- ---------- Geography ----------
        -- Socrata sends lat/lng as VARCHAR. Cast to DOUBLE so spatial
        -- queries and BI tools don't have to. NULL out the (0, 0)
        -- placeholder values that some upstream systems use to mean
        -- "unknown location" — they would otherwise plot in the Atlantic.
        case
            when try_cast(latitude  as double) = 0 then null
            else try_cast(latitude  as double)
        end                                                 as latitude,
        case
            when try_cast(longitude as double) = 0 then null
            else try_cast(longitude as double)
        end                                                 as longitude,

        nullif(trim(street_address), '')                    as street_address,
        nullif(trim(ward), '')                              as ward,
        nullif(trim(precinct), '')                          as precinct,
        nullif(trim(council_district), '')                  as council_district

    from source

)

select * from renamed
