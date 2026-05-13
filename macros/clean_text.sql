{#
    macros/clean_text.sql

    Normalizes a text column by trimming whitespace, lowercasing,
    and converting empty strings to NULL. The combined pattern
    `nullif(lower(trim(col)), '')` appears multiple times in our
    staging layer; centralizing it eliminates a typo class and
    makes the intent explicit.

    Usage in a model:

        select
            {{ clean_text('offense_description') }} as offense_description,
            {{ clean_text('offense_category')   }} as offense_category
        from {{ source('memphis', 'incidents') }}

    The macro returns a SQL fragment. dbt's compiler substitutes it
    inline at parse time, so the compiled SQL looks identical to
    what we'd have written by hand. Nothing magic — it's
    string-templating.

    A "macro" in dbt is just a Jinja function. The {% macro %} /
    {% endmacro %} block defines it; calling it with {{ name(args) }}
    returns the rendered content. Macros can take arguments, use
    Jinja control flow (if/for), call other macros, and access
    dbt's internal API (adapter, target, ref, source, etc.).
#}

{% macro clean_text(column_name) %}
    nullif(lower(trim({{ column_name }})), '')
{% endmacro %}
