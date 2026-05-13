{#
    snapshots/snap_offense_categories.sql

    SCD type-2 history of how each offense_description maps to an
    offense_category. The Memphis Police Department occasionally
    reclassifies offenses upstream (e.g., a code shifts from
    "property crime" to "theft"). A standard dim_offense build
    captures only the *current* mapping; this snapshot captures
    the full history.

    Snapshot mechanics (`strategy='check'`):
      - On each `dbt snapshot` run, dbt compares the current source
        rows (the SELECT below) to the snapshot table.
      - For each row whose unique_key already exists, dbt checks
        whether any value in `check_cols` changed.
      - If yes, dbt closes the old row (sets dbt_valid_to = now)
        and inserts a new row (dbt_valid_from = now).
      - If no, the existing row is untouched.
      - New unique_keys get inserted with dbt_valid_to = NULL
        (the "currently valid" row).

    The snapshot table grows monotonically — old versions stay
    around forever. That's the value proposition: you can ask
    "what category was 'auto burglary' classified as on 2023-06-15?"
    by filtering dbt_valid_from <= '2023-06-15' < dbt_valid_to.

    Grain: one row per (offense_description, time-validity window).
    The natural key is offense_description, because that's the
    source-system identifier whose classification we're tracking
    over time. If we used offense_key (the md5 hash of
    description+category), a category change would change the key
    and break SCD2 entirely.
#}

{% snapshot snap_offense_categories %}

{{
    config(
        target_schema='snapshots',
        unique_key='offense_description',
        strategy='check',
        check_cols=['offense_category'],
    )
}}

select distinct
    offense_description,
    offense_category
from {{ ref('stg_memphis__incidents') }}
where offense_description is not null

{% endsnapshot %}
