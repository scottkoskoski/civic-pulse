-- tests/assert_incident_date_not_future.sql
--
-- A "singular" test: a hand-written SELECT that should return zero
-- rows. dbt runs it as part of `dbt test`. Any row it returns is
-- a failure, and dbt prints those rows so you can investigate.
--
-- Why this test exists: Socrata occasionally includes typo'd dates
-- from records entered by hand at MPD, e.g. "2202-04-15" instead of
-- "2022-04-15". A generic `not_null` test would miss them — the
-- value isn't null, it's just impossible. We assert positively
-- that no offense_date is in the future.
--
-- This complements the generic tests in _stg_models.yml. Use
-- singular tests when the invariant is too specific to be a generic
-- test, or when phrasing it as a one-off SELECT is clearer than
-- defining a custom generic test.

select
    incident_id,
    offense_date
from {{ ref('stg_memphis__incidents') }}
where offense_date > current_date
