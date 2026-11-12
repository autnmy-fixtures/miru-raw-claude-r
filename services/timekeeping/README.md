# Timekeeping

The new service of `docs/architecture/timekeeping-soa.md` (§3, §11.1): a Rails 8.1 API-only
application on Ruby 4.0.1, with its own bundle and its own database. It will own time entries and
their billing reservations, and serve them only on its internal API (§5).

This is the **service shell**. It boots, connects to its own database, reads the shared library in
`packages/timekeeping_reservations`, and answers every error as a contract problem. It serves no
entry, reservation or relay route yet; those land lane by lane (§14).

## What is here

| Path | What |
|---|---|
| `config/application.rb` | API-only, Active Record and Action Controller only. The exceptions app renders framework errors as problems. |
| `config/database.yml` | `timekeeping_development` / `timekeeping_test`; `DATABASE_URL` in production. No database is shared with the existing application (§11.2). |
| `config/initializers/timekeeping.rb` | Loads the reservation decision table and points at the contracts in `../../packages/timekeeping_reservations`. Reads `TIMEKEEPING_TOKEN_KEY` and `EXISTING_APP_URL` from the environment. |
| `app/models/problem.rb` | One `application/problem+json` body. Its types are read from `common.json`, so only a type the contract lists can be built. |
| `app/controllers/problems_controller.rb` | The exceptions app: an unknown route is `404 not-found`; an unparseable body, unknown method or format is `invalid-request`. A status with no problem type answers with no body. |
| `GET /up` | Liveness, 200 once booted. |

## Configuration (§11.2)

Each value comes from this process's environment; none sits in a checked-in file.

| Variable | Kind | Use |
|---|---|---|
| `DATABASE_URL` | credential | This service's database (production). Locally, `DB_HOST`, `DB_USER` and `DB_PASS` as in the existing application. |
| `TIMEKEEPING_TOKEN_KEY` | credential | The key shared with the existing application to sign and verify tokens (§6.1). |
| `EXISTING_APP_URL` | plain | Where the relay delivers entry snapshots (§5.4). |
| `RAILS_MAX_THREADS`, `PORT` | plain | Puma. `PORT` defaults to 3100, next to the existing application's 3000. |

## Tests

From this directory, with Postgres reachable as for the existing application:

```sh
bin/rails db:prepare
bundle exec rspec
```

With the repository's test container: `miru-test 'cd services/timekeeping && bin/rails db:prepare && bundle exec rspec'`.
This suite is where the provider side of the contract tests runs (§12.3): `spec/support/contracts.rb`
checks answers against the same schemas the existing application's consumer and fakes read. It has its
own bundle, so the existing application's CI job (`bin/parallel_test`) does not run it; a CI job of its
own is not wired up yet.
