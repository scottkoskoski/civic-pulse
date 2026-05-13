-- models/marts/fct_incidents.sql
--
-- Incident fact table. Grain: one row per reported incident.
--
-- Lesson 7 refactor: now incremental. The first dbt build is a
-- full table-as-select; subsequent builds only process staging
-- rows whose offense_datetime is newer than what's already in
-- the fact (minus a 7-day lookback for late-arriving data),
-- merging on incident_id to handle the rare case where a row
-- gets updated upstream.
--
-- The unique_key + merge strategy means re-ingesting the entire
-- raw dataset (full-refresh of the loader) and then running
-- `dbt build` still produces correct results — duplicates merge
-- by incident_id, no manual cleanup needed.
--
-- To rebuild from scratch (e.g., schema changes, want a clean
-- table): `dbt build --select fct_incidents --full-refresh`.

{{ config(
    materialized='incremental',
    unique_key='incident_id',
    on_schema_change='append_new_columns'
) }}

with incidents as (

    select * from {{ ref('stg_memphis__incidents') }}

    {% if is_incremental() %}
    -- Incremental filter: only process staging rows newer than
    -- the latest already-stored offense_datetime, minus a 7-day
    -- lookback window to catch late-arriving / backdated rows.
    -- The merge step then de-duplicates by incident_id.
    --
    -- {{ this }} is a Jinja reference to the model currently being
    -- built — i.e., the existing fct_incidents table in the
    -- warehouse. We use it to look up the high-water mark.
    where offense_datetime >= (
        select coalesce(max(offense_datetime), '1900-01-01'::timestamp)
             - interval '7 days'
        from {{ this }}
    )
    {% endif %}

),

joined as (

    select
        i.incident_id,

        (year(i.offense_date)  * 10000
       + month(i.offense_date) * 100
       + day(i.offense_date))                       as date_key,

        {{ dbt_utils.generate_surrogate_key([
            'i.ward',
            'i.precinct',
            'i.council_district',
        ]) }} as location_key,

        {{ dbt_utils.generate_surrogate_key([
            'i.offense_category',
            'i.offense_description',
        ]) }} as offense_key,

        i.offense_datetime,
        i.latitude,
        i.longitude,
        i.street_address,

        1::int                                      as incident_count

    from incidents i

)

select * from joined
