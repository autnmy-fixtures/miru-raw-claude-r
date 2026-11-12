# Timekeeping

The new service of `docs/architecture/timekeeping-soa.md` (§3, §11.1): a Rails 8.1 API-only
application on Ruby 4.0.1, with its own bundle and its own database. It will own time entries and
their billing reservations, and serve them only on its internal API (§5).

It boots, connects to its own database, reads the shared library in
`packages/timekeeping_reservations`, answers every error as a contract problem, and holds its copy
of the ownership record (§10.1). It holds entries and their reservations and serves the entry API's
reads: list, show and invoice candidate selection (§5.2), its single-entry writes: create,
update and discard, W2's bulk move and bulk discard, W5's import batches and W6's agent detach.
The reservation API and the relay land lane by lane (§14).

## What is here

| Path | What |
|---|---|
| `config/application.rb` | API-only, Active Record and Action Controller only. The exceptions app renders framework errors as problems. |
| `config/database.yml` | `timekeeping_development` / `timekeeping_test`; `DATABASE_URL` in production. No database is shared with the existing application (§11.2). |
| `config/initializers/timekeeping.rb` | Loads the reservation decision table and points at the contracts in `../../packages/timekeeping_reservations`. Reads `TIMEKEEPING_TOKEN_KEY` and `EXISTING_APP_URL` from the environment. |
| `app/models/problem.rb` | One `application/problem+json` body. Its types are read from `common.json`, so only a type the contract lists can be built. |
| `app/controllers/problems_controller.rb` | The exceptions app: an unknown route is `404 not-found`; an unparseable body, unknown method or format is `invalid-request`. A status with no problem type answers with no body. |
| `db/migrate/*_create_ownerships.rb`, `app/models/ownership.rb` | Timekeeping's copy of the ownership record (§10.1): one row, `(generation, owner, state)`, defaults the initial legacy state. `Ownership.admit!(generation)` is the admission every mutating call runs inside its own write transaction: it holds the row `FOR SHARE` and refuses with a contract problem, `409 stale-generation` when the call carries another generation or Timekeeping does not own entries, and a retryable `503 ownership-moving` while a handoff has admission closed or frozen. |
| `app/services/handoff_fence.rb` | The only code that changes the copy: close, freeze, flip and abort (§10.5), each in one transaction that takes the row `FOR UPDATE`, so close waits for every admitted call. The steps are the shared state machine, `TimekeepingReservations::Handoff`, which the existing application's copy moves through too. |
| `db/migrate/*_create_entries.rb`, `app/models/entry.rb` | Timekeeping's entries (§3.2): every column of `timesheet_entries`, the same ids, plus `company_id` (§6.3) and `version`. Enums are stored by the names the contracts carry. `Entry#to_contract` is the contract's full entry; `locked` is not stored but derived from the entry's reservations by the shared rule (§7.1). |
| `db/migrate/*_create_reservations.rb`, `app/models/reservation.rb` | Each entry's reservations (§7.1), with the same constraints and indexes as the prepared application's `timekeeping_reservations`, and a foreign key to the entry. Nothing writes them yet; the reservation API will. |
| `app/models/user_token.rb` | Verifies the user token (§6.1): HS256 with the shared key, unexpired, claims valid against `entry_api.json#/$defs/token_claims`. |
| `app/models/contracts.rb` | Checks a payload against the shared contracts. Endpoints use it for what they accept; the specs use it for what they answer. |
| `app/controllers/internal/base_controller.rb` | Every internal endpoint: a valid token or `401 unauthenticated`, the contract's required headers, its mutating ones too for every call that is not a GET, or `400 invalid-request`, input checked against the contract, and any `Problem::Raised` answered as its problem. |
| `GET /internal/v1/entries`, `GET /internal/v1/entries/{id}` | The entry API's reads (§5.2, §3.3 rule 1): the kept entries of the token's company only (§6.3). The list takes the contract's filters and pages by id (`app/services/entry_list.rb`, 500 per page, the cursor is the last id answered). Another company's entry, a discarded one or a missing one is `404 not-found`. A read needs no admission (§10.1). |
| `GET /internal/v1/candidates` | Invoice candidate selection (§5.2, §3.3 rule 1), `app/services/candidate_list.rb`: the kept, unbilled entries of the token's company in the query's `project_ids`, narrowed by `user_ids`, `exclude_ids`, `from`/`to` and `search_term`, leaving out every entry the shared rule finds not selectable (an active or provisional reservation; a retained one does not count, L3, L4). `search_term` is the existing application's `TimesheetEntry.pg_search`, written out as the SQL pg_search builds: english tsearch over `note`, each word a prefix, every word required, ordered by rank and then id. `client_id` narrows nothing: the gateway resolves the client's kept projects into `project_ids`. |
| `POST /internal/v1/entries` | Entry create (§5.2) for W1, W3 and W4, `app/services/entry_create.rb`: the entry in the token's company, for the project the token names (any other is `403 forbidden`), with the acting agent from the token. TimesheetEntry's create rules run in `Entry`, in its order and only in the writer's context `Entry::CREATE`: bill status from the project, A10's pending review and source rewrite, metadata normalized, and a billed entry, an unbilled one on a non-billable project, a duration out of range or a proof URL too long refused as `422 validation-failed` with the model's errors by attribute, worded as `config/locales/errors.en.yml` there. Two of today's checks stay with the gateway, which holds the directory: the agent's company and user, and that the user and project exist. |
| `PATCH /internal/v1/entries/{id}`, `DELETE /internal/v1/entries/{id}` | Entry update and discard (§5.2) for W1 and W3, `app/services/entry_update.rb` and `entry_discard.rb`. Each holds the kept entry of the token's company `FOR UPDATE` (another company's, a discarded or a missing one is `404 not-found`) and checks A3-A5 against that row (`app/services/entry_policy.rb`): billed is refused to everyone, outside the edit window and someone else's entry to all but owner and admin, each `403 forbidden`. Update then requires the token to name the entry's resulting project and runs TimesheetEntry's update rules in `Entry::UPDATE`: A10's review status, metadata and source normalized, the field checks, the non-billable project check, and the edit lock, which refuses an employee with TimesheetEntry's own message as `422 validation-failed`. Discard runs no rule, as today's `discard!` runs none, so an employee may discard their own locked entry. Each change saves the entry's next version with an `update` audit row (each audited column as `[before, after]`) and an outbox snapshot; an update that changes nothing writes nothing. There is no `PUT`. `app/services/entry_command.rb` holds the steps create, update and discard share. |
| `POST /internal/v1/entries/bulk_move`, `POST /internal/v1/entries/bulk_discard` | W2's bulk writes (§5.2, §6.2), `app/services/entry_bulk.rb`, one call and one transaction each (§3.4). Each holds the named kept entries of the token's company `FOR UPDATE` in id order (another company's, a discarded or a missing id is left out, as the caller's selection leaves it out) and checks A9's lock on every one (`EntryPolicy.lock!`, today's `BulkActionController#entry_locked?`): one billed entry, or one outside the edit window for anyone but owner and admin, refuses the whole request as `403 entry-locked` with nothing written. A move requires the token to name the target project, runs TimesheetEntry's update rules on each entry in `Entry::UPDATE`, and skips an entry they reject, answering 200 with it in `skipped_ids` (A9's silent skip, K12: an employee's locked entry, or an unbilled entry moved to a non-billable project); `entries` is every held entry as it stands after the move. A discard runs no rule, as today's `discard_all` runs none. Each changed entry gets its next version, an `update` audit row with writer `bulk`, and an outbox snapshot. |
| `POST /internal/v1/imports/{import_id}/batches/{n}` | W5's Harvest import batch (§3.4, §5.2), `app/services/entry_import.rb`: one call and one transaction per batch of at most 500 rows, idempotent by the gateway's `import_id:batch_no` key. The token is the import job's system actor and carries the facts of every project the rows name in its `projects` claim (§6.1); a row naming any other, or one of another company, refuses the whole batch as `403 forbidden` with nothing written. Each row is created under TimesheetEntry's create rules in `Entry::CREATE` with its project's facts; a row they reject is never inserted and is answered in `failed_rows` by its index with the model's errors by attribute, and the rest of the batch is kept, as today's savepoint per row keeps it. A billed row is created unbilled and then marked billed, as today's `create!` then `update!` (§1.3): two versions, a `create` and an `update` audit row with writer `import`, and two snapshots. |
| `POST /internal/v1/agents/{agent_id}/detach` | W6's agent detach (§3.1, §5.2), `app/services/entry_detach.rb`: what today's `dependent: :nullify` (`update_all(agent_id: nil)`, K8) does, as one call and one transaction. It holds every entry of the token's company that names the agent `FOR UPDATE` in id order, discarded ones included as `update_all` reaches them, and nulls its `agent_id` as its next version, with an `update` audit row with writer `agent_destroy` and an outbox snapshot. No rule runs and no role is read; the company is the only check (§6.2), so another company's entry naming the same id is untouched. `updated_at` is kept, as `update_all` keeps it. An agent no entry names answers no ids, so a repeat under a new key is harmless. |
| `app/services/entry_write.rb` | One mutating call (§3.4, §9.4): in one transaction, admission under `X-Ownership-Generation`, then the stored answer for the call's `Idempotency-Key` or the change and its receipt. A refusal rolls everything back and stores no receipt. Calls carrying one key in one tenant are serialized by an advisory lock until the first commits, so a retry that overtakes its first attempt replays it. |
| `app/services/entry_change.rb` | What every entry change writes beside the entry, in its transaction: an `entry_audits` row (the columns `audited` records on TimesheetEntry today, the actor, agent, writer and request id) and an `outbox_snapshots` row, the contract's entry snapshot, whose id is the outbox position (§5.4, §10.5 step 3). The relay that delivers them is not here yet. |
| `db/migrate/*_create_idempotency_receipts.rb`, `app/models/idempotency_receipt.rb` | `(key, request hash, response)` per tenant (§9.4): the same key and request replay the answer, the same key and another request is `409 idempotency-conflict`, another company's same key is its own call. |
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
