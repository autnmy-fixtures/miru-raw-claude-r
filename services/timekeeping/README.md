# Timekeeping

The new service of `docs/architecture/timekeeping-soa.md` (§3, §11.1): a Rails 8.1 API-only
application on Ruby 4.0.1, with its own bundle and its own database. It will own time entries and
their billing reservations, and serve them only on its internal API (§5).

It boots, connects to its own database, reads the shared library in
`packages/timekeeping_reservations`, answers every error as a contract problem, and holds its copy
of the ownership record (§10.1). It holds entries and their reservations and serves the entry API's
reads: list, show and invoice candidate selection (§5.2), its single-entry writes: create,
update and discard, W2's bulk move and bulk discard, W5's import batches and W6's agent detach,
and the reservation API: prepare, commit and abort (§5.3). It loads the first cutover's checkpoint
(§10.5 steps 4 and 5) and reconciles what it then holds against that checkpoint (step 6), takes the rollback's checkpoint from what it holds (step 4, as the outgoing owner), and loads the re-cutover's checkpoint over what it still holds from before the rollback (steps 4 and 5, as the incoming owner again) and reconciles what it then holds against it (step 6); the handoff tool reaches all of it, and the fence on its copy of the ownership record, over the handoff API. Its relay delivers every entry snapshot
in its outbox to the existing application's projection consumer (§5.4), on its own queue and worker.

## What is here

| Path | What |
|---|---|
| `config/application.rb` | API-only, Active Record and Action Controller only. The exceptions app renders framework errors as problems. |
| `config/database.yml` | `timekeeping_development` / `timekeeping_test`; `DATABASE_URL` in production. No database is shared with the existing application (§11.2). |
| `config/initializers/timekeeping.rb` | Loads the reservation decision table and points at the contracts in `../../packages/timekeeping_reservations`. Reads `TIMEKEEPING_TOKEN_KEY` and `EXISTING_APP_URL` from the environment. |
| `app/models/problem.rb` | One `application/problem+json` body. Its types are read from `common.json`, so only a type the contract lists can be built. |
| `app/controllers/problems_controller.rb` | The exceptions app: an unknown route is `404 not-found`; an unparseable body, unknown method or format is `invalid-request`. A status with no problem type answers with no body. |
| `db/migrate/*_create_ownerships.rb`, `app/models/ownership.rb` | Timekeeping's copy of the ownership record (§10.1): one row, `(generation, owner, state)`, defaults the initial legacy state. `Ownership.admit!(generation)` is the admission every mutating call runs inside its own write transaction: it holds the row `FOR SHARE` and refuses with a contract problem, `409 stale-generation` when the call carries another generation or Timekeeping does not own entries, and a retryable `503 ownership-moving` while a handoff has admission closed or frozen. The one exception is the settle step's (§10.5 step 2): `Ownership#settling?` is true for a call carrying an older generation while Timekeeping is the outgoing owner and the handoff is `closed`, and `admit!(generation, settle: true)`, which only the reservation API's commit and abort pass, admits it. Freeze or an aborted handoff ends it. `Ownership.lock_frozen!(step, generation, owner:)` is the guard of a checkpoint step on this copy: the row held `FOR SHARE`, or `OutOfStep` unless it is `frozen` under that outgoing owner at that generation. `Ownership.lock_frozen_legacy!(step, generation)` is that guard for the first cutover's steps (load, reconcile), under owner `legacy`. |
| `app/services/handoff_fence.rb` | The only code that changes the copy: close, freeze, flip and abort (§10.5), each in one transaction that takes the row `FOR UPDATE`, so close waits for every admitted call. The steps are the shared state machine, `TimekeepingReservations::Handoff`, which the existing application's copy moves through too. |
| `app/services/checkpoint_load.rb` | Steps 4 and 5 of the first cutover on this side (§10.5, §10.3): `CheckpointLoad.call(generation:, entries:, reservations:, request_id:)` loads the checkpoint the existing application took from the legacy owner (`Timekeeping::LegacyCheckpoint` there; the handoff tool carries it across). It runs only while this copy is `frozen` under owner `legacy` at the handoff's generation, holding the row `FOR SHARE`, and only into a Timekeeping that holds no entries yet (`AlreadyLoaded` otherwise, so a resumed handoff goes on to reconcile). In one transaction it inserts every entry and every committed reservation exactly as carried, with no writer's rule, callback or audit row (§8 item 1), one outbox snapshot per entry at its checkpoint version so the relay replaces the projection's legacy row (§3.2), and sets `entries_id_seq` above the highest loaded id without ever moving it back. A checkpoint that does not hold together is refused whole as `Refused`, listing the entry ids per check: an entry the contract does not allow, a reservation whose entry or tenant the checkpoint does not hold, a provisional reservation, or a `locked` its reservations do not derive. |
| `app/services/checkpoint_reconcile.rb` | Step 6 of the first cutover on this side (§10.5, §10.4 "Reconciliation"): `CheckpointReconcile.call(generation:, entries:, reservations:)` compares what Timekeeping holds with the checkpoint the handoff tool carried to the load, under the same guard (`frozen` under owner `legacy` at the handoff's generation, the row held `FOR SHARE`). It covers the rows of §10.4's table whose target is the incoming owner, each exact: every column of every entry by id, `version` and the derived `locked` included; each entry's reservations (invoice, tenant, state, `edit_lock`, disposition); and receipts, of which the legacy owner keeps none, so any held reservation operation or idempotency receipt is a difference. It writes nothing. Any difference raises `Differs`, listing per check the entry ids (or receipt identifiers) it found, and the handoff tool aborts the handoff. The rows that read the existing application's tables (reservations against kept invoices, the projection, money) are reconciled there, by `Timekeeping::CheckpointReconcile` against the same checkpoint. |
| `app/services/checkpoint_take.rb` | Step 4 of the rollback on this side (§10.2 step 6, §10.5 step 4): `CheckpointTake.take(generation:)` reads the frozen checkpoint the handoff tool carries to the prepared existing application (the `monolith` owner). It runs only while this copy is `frozen` under owner `timekeeping` at the handoff's generation, holding the row `FOR SHARE` before it reads anything else, so the fence cannot flip or abort under it. It answers a `Checkpoint` holding what §10.5 step 4 lists: every entry, discarded ones included, as the contract's full entry at the version held here (the projection already has these versions, so nothing is renumbered) with `locked` derived from its reservations; every reservation as a `TimekeepingReservations::Reservation`, a destroyed non-draft's retained one included (§7.3); the entry audit rows with their ids; every terminal reservation-operation receipt, the no-op abort of one never prepared included; and the entry API's idempotency receipts of every tenant. `highest_entry_id` is what the incoming owner's sequence is set above (§10.3). `CheckpointTake.held` is the same read with no guard of its own, for a caller that already holds the record (`RecutoverLoad`). Values are copied as stored, in the form JSON carries unchanged: the float `duration`, timestamps in UTC to the microsecond, JSON columns as stored. No pending billing operation crosses (§10.5 step 2): a provisional reservation or an operation still `prepared` raises `Unsettled`, listing the entry ids and `invoice_id/operation_id`, and nothing is taken. It writes nothing. |
| `app/services/recutover_load.rb` | Steps 4 and 5 of the re-cutover on this side (§10.2 step 6, §10.5, §10.3): `RecutoverLoad.call(checkpoint)` loads the checkpoint the existing application took out of the prepared application (`Timekeeping::LocalCheckpoint` there, the rollback's `taken_checkpoint` shape; the handoff tool carries it across). It runs only while this copy is `frozen` under owner `monolith` at the handoff's generation, holding the row `FOR SHARE` before it reads anything else. Timekeeping still holds what it held at the rollback, so the checkpoint replaces it: entries are written over by id, every column as carried (they are never deleted, because the outbox refers to them), and reservations, audit rows with their ids, terminal operation receipts and idempotency receipts are replaced by the checkpoint's. Then it sets `entries_id_seq` and `entry_audits_id_seq` above the highest carried ids, and never moves either back. It all happens in one transaction, with no writer's rule, callback, audit row or outbox snapshot: freeze drained the prepared application's outbox into the projection, so it already holds the carried versions. Loading the same checkpoint again leaves the same tables, so a resumed handoff can run it again. A checkpoint is refused whole as `Refused` (the first cutover's, so the API answers it the same way), listing what each check found, in two cases. First, when it does not hold together: the first cutover's entry and reservation checks, plus audit rows, receipts and idempotency receipts the contract does not allow, and an audit row whose entry or tenant it does not hold. Second, when it would drop what Timekeeping holds (§13 item 3): an entry not carried, carried at an older version, or carried at the same version with other content; or an audit row, operation receipt or idempotency receipt not carried exactly as held. Those rows never change once written. Reservations are the outgoing owner's and are not compared. |
| `app/services/recutover_reconcile.rb` | Step 6 of the re-cutover on this side (§10.2 step 6, §10.5 step 6, §10.4 "Reconciliation"): `RecutoverReconcile.call(checkpoint)` compares what Timekeeping holds once `RecutoverLoad` has run with the same checkpoint, under the same guard (`frozen` under owner `monolith` at the handoff's generation, the row held `FOR SHARE` before it reads anything else). It covers the rows of §10.4's table whose target is the incoming owner, each exact and each both ways (missing, unexpected, differs): entries by id, every column, `version` and the derived `locked` included; each entry's reservations as a set (owner, tenant, state, `edit_lock`, disposition); audit rows by id; terminal operation receipts by `invoice_id/operation_id`; and idempotency receipts by `company_id/key`. It reads Timekeeping's tables through `CheckpointTake.held`, the rendering the load compares against, and compares each value from both sides, so a value not in contract form (a `Time` where the contract carries a string) differs instead of being coerced equal. Reservations against kept invoices, the projection and money are reconciled in the existing application. It writes nothing: any difference raises `CheckpointReconcile::Differs` (the first cutover's, so the API can answer both as `checkpoint-differs`), listing what each check found, and the handoff is aborted. On success it answers how many rows of each part it reconciled. |
| `db/migrate/*_create_entries.rb`, `app/models/entry.rb` | Timekeeping's entries (§3.2): every column of `timesheet_entries`, the same ids, plus `company_id` (§6.3) and `version`. Enums are stored by the names the contracts carry. `Entry#to_contract` is the contract's full entry; `locked` is not stored but derived from the entry's reservations by the shared rule (§7.1). |
| `db/migrate/*_create_reservations.rb`, `app/models/reservation.rb` | Each entry's reservations (§7.1), with the same constraints and indexes as the prepared application's `timekeeping_reservations`, and a foreign key to the entry. Only the reservation API writes them. |
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
| `POST /internal/v1/invoices/{invoice_id}/operations/{operation_id}/prepare`, `/commit`, `/abort` | The reservation API (§5.3), `app/services/reservation_protocol.rb`, decided by the shared decision table (§7.2) and kept to the protocol the prepared application's `Timekeeping::LocalReservations` keeps. Each call is one transaction: admission under `X-Ownership-Generation`, a per-invoice advisory lock, then the invoice's tenant: an invoice whose operations belong to another company is `404 not-found` to every call (§6.3). The `Idempotency-Key` must be the path's `operation_id` and the body's `generation` must be the header's, or `400 invalid-request`; a prepare body naming another company than the token's is `403 forbidden`. Prepare reserves the added entries provisionally (with the edit lock on a draft), records the operation, and answers every entry of the desired set with the facts line-item validation needs; an entry another kept invoice holds active, or another operation holds provisionally, is refused (`on_other_invoice`, F1), as are another company's (`wrong_company`, L8) and a missing one (`not_found`), all in one `409 reservation-refused` with nothing reserved. Commit applies the table's commit effect and abort drops only the operation's provisional reservations. All three are idempotent by `(invoice_id, operation_id)`: a terminal operation answers its stored receipt, `committed` or `aborted`, to every later call; a prepare replayed with another body is `409 idempotency-conflict`; a commit of an operation never prepared is `404 not-found`; an abort of one leaves an `aborted` receipt, so its late prepare changes nothing (§9.3). An invoice has at most one unresolved operation (`db/migrate/*_create_reservation_operations.rb`, `app/models/reservation_operation.rb`): a new prepare carries its outcome in `resolves`, or is a retryable `409 operation-unresolved`. Every entry whose reservations change gets its next version and an outbox snapshot carrying the derived `locked` (§5.4), and no audit row, as `locked` is not audited; `updated_at` moves only when `locked` does. The entries a change touches are held `FOR UPDATE` in id order, so two invoices preparing one entry serialize and one is refused. During a handoff's settle step, while Timekeeping is the outgoing owner, commit and abort are still applied under the old generation, but only for an operation Timekeeping registered (§10.5 step 2): a commit of any other is `409 stale-generation`, and an abort of one is the usual no-op `aborted` receipt (§9.3), so the abort the existing application recorded for a prepare that never arrived lets settle finish. Prepare under the old generation stays stale. |
| `GET /internal/v1/handoff`, `POST /internal/v1/handoff/steps/{step}`, `GET /internal/v1/handoff/checkpoint`, `POST /internal/v1/handoff/checkpoint`, `POST /internal/v1/handoff/checkpoint/reconcile`, `POST /internal/v1/handoff/recutover/checkpoint`, `POST /internal/v1/handoff/recutover/checkpoint/reconcile` | The handoff API (`handoff_api.json`, §10.1, §10.5), `app/controllers/internal/v1/handoffs_controller.rb`: how the handoff tool, run from the existing application, reaches this side of the procedure. Only the tool's service token is accepted (`app/models/handoff_token.rb`: audience `handoff`, subject `service:timekeeping-handoff`), never a user token or the relay's. The read answers this copy of the ownership record and where the relay stands: the latest outbox position and how many snapshots are still undelivered, so the tool knows when the projection holds everything through that position. A step runs `HandoffFence` (close, freeze, flip or abort; any other is `404 not-found`), and load and reconcile run `CheckpointLoad` and `CheckpointReconcile` on the checkpoint as carried; each answers the record or a receipt `{ entries, reservations }`. The checkpoint read (`?generation=`) runs `CheckpointTake` for a rollback and answers the whole checkpoint (`taken_checkpoint`): entries, committed reservations, audit rows, terminal operation receipts and idempotency receipts, as stored; settle having left an operation unresolved is `409 checkpoint-unsettled`, listing the entry ids and `invoice_id/operation_id` it found. The re-cutover's load runs `RecutoverLoad` on the checkpoint taken out of the prepared existing application, in the same parts (`recutover_checkpoint`: each row need only name what identifies it, an entry its id and version, so the load's own checks answer the rest), and answers how many rows of each part it loaded (`recutover_receipt`); run again it leaves the same tables and answers the same. The re-cutover's reconcile runs `RecutoverReconcile` on the same checkpoint, carried again in the same request, and answers the same counts; it writes nothing, so the tool may ask as often as it needs. The calls are not admitted writes: each service guards itself by the step the copy is at, so a replay is `409 out-of-step` and changes nothing, a second first-cutover load `409 already-loaded`, and no `Idempotency-Key` is needed. `X-Ownership-Generation` must equal the body's `generation`. A step whose lock waits out the calls already admitted is a retryable `503 drain-timeout`; a checkpoint that does not hold together `422 checkpoint-refused`, and a reconcile difference `409 checkpoint-differs`, each listing what each check found (entry ids, audit ids or receipt identifiers) in the problem's `lists`. A checkpoint body is read exactly as sent, not through Rails' parameter parsing, which would rewrite a `[null]` inside an entry's metadata. |
| `app/services/entry_write.rb` | One mutating call (§3.4, §9.4): in one transaction, admission under `X-Ownership-Generation`, then the stored answer for the call's `Idempotency-Key` or the change and its receipt. A refusal rolls everything back and stores no receipt. Calls carrying one key in one tenant are serialized by an advisory lock until the first commits, so a retry that overtakes its first attempt replays it. |
| `app/services/entry_change.rb` | What every entry change writes beside the entry, in its transaction: an `entry_audits` row (the columns `audited` records on TimesheetEntry today, the actor, agent, writer and request id) and an `outbox_snapshots` row, the contract's entry snapshot, whose id is the outbox position (§5.4, §10.5 step 3). `OutboxRelay` delivers them. |
| `app/services/outbox_relay.rb` | The relay (§5.4): the outbox's undelivered snapshots, in outbox order and batches of 500, posted to `EXISTING_APP_URL` + `/internal/v1/projection/entry_snapshots` as `entry_snapshot.json`'s `deliver_snapshots`, with the relay's service token (audience `projection`, 60 s TTL) and an `X-Request-Id` of its own, logged with the request ids of the changes it carries (§11.3). One batch is one transaction: its rows taken `FOR UPDATE SKIP LOCKED`, so an overlapping run delivers other rows or none, and marked `delivered_at` only once the consumer answers the contract's 200 receipt. Any other answer, or none within 10 s, rolls the batch back unmarked; it is logged and reported, and the next run sends it again. Nothing is skipped, and the consumer's upsert by version makes a resend harmless. Delivery is marked per row, not as one position, because changes commit in any order: a row below a delivered position can still appear, and is still sent (`db/migrate/*_add_delivered_at_to_outbox_snapshots.rb`). |
| `app/jobs/outbox_relay_job.rb`, `config/solid_queue.yml` | The relay's runtime (§11.1, D3): `OutboxRelayJob` on the `timekeeping_relay` queue, enqueued every second by the dispatcher and run by one dedicated worker that reads no other queue, on this service's own Solid Queue tables (`db/migrate/*.solid_queue.rb`). Start it with `bin/rails solid_queue:start`; stopping it pauses the relay (§12.4), and the outbox keeps every change until it resumes. |
| `app/services/signals.rb`, `app/jobs/signals_job.rb`, `lib/tasks/signals.rake` | Timekeeping's side of the observability table (§11.3). **Relay lag**: how long the oldest undelivered outbox snapshot has waited, and the positions from it to the latest; it alerts when the lag is above 60 s now and was at every moment of the last 5 minutes, read from the outbox's `created_at` and `delivered_at` alone, so a restarted reader gives the same answer. `SignalsJob` reads it every 15 s on `timekeeping_relay`, the only queue Timekeeping runs (§11.1), so it catches a relay that runs but cannot deliver; a stopped worker is read with `bin/rails timekeeping:signals` from any process, which prints each signal and exits 1 on an alert, reporting nothing itself. **Stale-generation refusals outside a handoff**: reported as they happen, from the internal API's answer, when the record the refusal read under its lock was open. Both copies are closed or frozen from a handoff's first step to its flip or abort, so an open copy means no handoff is in progress. The settle step's refusals, made while closed, are not reported, and every refusal is answered exactly as before. **Reconciliation differences**: reported as the handoff API answers `checkpoint-differs`. Every alert goes to `Rails.error` (severity `error`, with the signal and its details) and to the log at error level. |
| `config/initializers/sentry.rb` | Sentry, as in the existing application: `SENTRY_DSN` from the environment, enabled in production and staging only, and every error and transaction event tagged `service: "timekeeping"` (§11.3). |
| `db/migrate/*_create_idempotency_receipts.rb`, `app/models/idempotency_receipt.rb` | `(key, request hash, response)` per tenant (§9.4): the same key and request replay the answer, the same key and another request is `409 idempotency-conflict`, another company's same key is its own call. |
| `GET /up` | Liveness, 200 once booted. |
| `Dockerfile`, `Dockerfile.dockerignore`, `bin/docker-entrypoint` | Timekeeping's own image (§11.1, §14 "Deployment and runtime"), built from the repository root. It holds this service and `packages/timekeeping_reservations`, at the same relative paths as in a checkout, and nothing of the existing application, so either image is rebuilt and restarted without the other (§13 item 4). Gems are installed without the test group, and the build fails if the application does not boot in production. The image runs as a non-root user, records the revision it was built from (label `org.opencontainers.image.revision`, env `TIMEKEEPING_REVISION`), and runs both processes: by default Puma on `PORT`, which first creates or migrates this service's database, Solid Queue's tables included; and `bin/rails solid_queue:start`, the relay's worker, which does not migrate, so it is started once the web process answers `GET /up`. |

## Configuration (§11.2)

Each value comes from this process's environment; none sits in a checked-in file.

| Variable | Kind | Use |
|---|---|---|
| `DATABASE_URL` | credential | This service's database (production). Locally, `DB_HOST`, `DB_USER` and `DB_PASS` as in the existing application. |
| `SECRET_KEY_BASE` | credential | Rails' own secret, which production needs to boot (Active Record builds its message verifier from it). This service has no encrypted credentials file, so there is no `RAILS_MASTER_KEY` to decrypt one; Rails reads `SECRET_KEY_BASE` from the environment instead. Nothing here signs a cookie or a session with it. |
| `TIMEKEEPING_TOKEN_KEY` | credential | The key shared with the existing application to sign and verify tokens (§6.1). |
| `EXISTING_APP_URL` | plain | Where the relay delivers entry snapshots (§5.4). The relay's worker refuses to run without it or the token key. |
| `SENTRY_DSN` | credential | Where errors and alerts are sent, a secret as in the existing application's `config/deploy.yml`. Unset, as in the local demo, nothing is sent. |
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
own bundle, so the existing application's CI job (`bin/parallel_test`) does not run it.

Its own CI is `bin/ci`, which runs the same on a developer machine as in a CI job:

```sh
services/timekeeping/bin/ci tests   # this suite on its own timekeeping_test database, then the package's specs
TIMEKEEPING_CI_DATABASE_URL=postgres://…/timekeeping_production services/timekeeping/bin/ci image
```

`image` builds this service's image from the repository root with the commit as `REVISION` (or
`REVISION` as given), checks the revision label, and boots it on that empty database with throwaway
credentials: the web process must migrate it and answer `GET /up`, and the relay's worker must start.
Both containers are removed when it ends. `spec/config/timekeeping_ci_spec.rb`, in the existing
application's suite, runs `image` against stand-ins for `docker` and `curl`. `tests` also runs
`packages/timekeeping_reservations/spec`, the decision table row by row (§12.3), which neither bundle's
suite loads.

`.github/workflows/timekeeping.yml` runs both steps as two jobs, `Timekeeping specs` and `Timekeeping
image`, on every push and pull request that changes this service, `packages/timekeeping_reservations`
or the workflow itself. Each job has its own throwaway Postgres service; the workflow only provides
Ruby and Postgres, and every step is in `bin/ci`. `spec/config/timekeeping_ci_spec.rb` checks that wiring.

To build and run the image, from the repository root:

```sh
docker build -f services/timekeeping/Dockerfile --build-arg REVISION="$(git rev-parse HEAD)" -t timekeeping .
docker run -e DATABASE_URL=… -e SECRET_KEY_BASE=… -e TIMEKEEPING_TOKEN_KEY=… -e EXISTING_APP_URL=… -p 3100:3100 timekeeping
docker run -e DATABASE_URL=… -e SECRET_KEY_BASE=… -e TIMEKEEPING_TOKEN_KEY=… -e EXISTING_APP_URL=… timekeeping bin/rails solid_queue:start
```

## The local demo runtime (§11.1, §11.2)

The demo runs both applications on one machine, each from its own image with its own Postgres server
and database. They share no database credential; the token key is the only credential they share.
There is no deploy lane and no Kamal configuration for it (§15.3). It is
`docker-compose.timekeeping-demo.yml` at the repository root, driven by `bin/timekeeping-demo`:

| Service | Image | Runs |
|---|---|---|
| `miru-web` | the existing application, `Dockerfile` target `development` | Falcon on `127.0.0.1:3000`. On a new database, `db:prepare` creates it and seeds the two businesses in the initial legacy state |
| `miru-jobs` | the same image | Solid Queue with `config/solid_queue_timekeeping_demo.yml`: the invoice operation worker (`invoice_operations`) and the prepared application's relay (`timekeeping_relay`), each also reading the other's §11.3 alerts, and nothing else |
| `miru-db` | `postgres:16-alpine` | the existing application's database, user `miru` |
| `timekeeping-web` | this service's `Dockerfile` | Puma on `127.0.0.1:3100`, migrating its own database first |
| `timekeeping-relay` | the same image | the relay's worker, on `timekeeping_relay` only |
| `timekeeping-db` | `postgres:16-alpine` | this service's database, user `timekeeping` |

The existing application's `default` worker, and its `billing_sync` worker, are never started (§11.1).
Seeding leaves integration and mail jobs queued on `default`, and the `default` worker would run them. Each
worker starts once its web process is healthy, so only the web processes migrate.

```sh
bin/timekeeping-demo init        # once: writes the credentials to tmp/timekeeping-demo/demo.env (0600)
bin/timekeeping-demo up          # builds both images, starts all six services, prints the versions
bin/timekeeping-demo versions    # each process's image id and the revision it was built from
bin/timekeeping-demo handoff first_cutover   # or rollback, recutover; each with :abort
bin/timekeeping-demo rebuild timekeeping     # rebuilds and restarts Timekeeping; the existing application stays as it is
bin/timekeeping-demo rebuild existing        # the other way round
bin/timekeeping-demo alternating-writers     # every writer across cutover, rollback and re-cutover (§12.4)
bin/timekeeping-demo contract-check          # every contract between the two running applications
bin/timekeeping-demo independent-deploys     # the independent-deployment proof (§13 item 4), recorded
bin/timekeeping-demo relay-paused            # the relay-paused proof (§13 item 5)
bin/timekeeping-demo compose stop timekeeping-relay   # pauses the relay (§12.4); `compose start` resumes it
bin/timekeeping-demo down        # stops everything; both databases and the handoff journals are kept
```

- **Credentials.** `init` generates each application's database password and `SECRET_KEY_BASE`, the
  shared `TIMEKEEPING_TOKEN_KEY`, and `MIRU_SEED_PASSWORD`, the seeded users' password (sign in to the
  existing application as, for example, `grace@forkandleaf.example` with it). The seeds' default,
  `password`, fails the breached-password check outside the test environment. The file is under the
  ignored `tmp/`, and `init` never overwrites it. Set `TIMEKEEPING_DEMO_ENV_FILE` to keep it elsewhere.
  Compose refuses to start when a credential is missing.
- **Wiring.** The existing application calls `TIMEKEEPING_URL=http://timekeeping-web:3100`, and the relay
  delivers to `EXISTING_APP_URL=http://miru-web:3000`. `RAILS_DEVELOPMENT_HOSTS=miru-web` lets that host
  through development's host authorization.
- **Handoffs.** The runners in `lib/tasks/timekeeping.rake` run inside `miru-web`. Their journals sit in
  the `miru_handoff_journals` volume, so an interrupted handoff can resume after a rebuild of the existing
  application. The first cutover reads the recorded seed disposition (§10.4) from
  `spec/fixtures/timekeeping/seed_disposition.yml`. The image leaves out `spec/`, so the demo mounts that
  file read-only at its default path.
- **Versions.** Each image records the commit it was built from, marked `-dirty` when the working tree
  differs from it: Timekeeping's as the `REVISION` build argument, the existing application's as a build
  label. `rebuild` rebuilds and recreates only the named application's two processes, web first. The
  independent rebuild-and-restart proof (§13 item 4) runs on this.
- **Independent deploys (§13 item 4).** `bin/timekeeping-demo independent-deploys` runs while Timekeeping
  owns the entries (after `handoff first_cutover`, or after the journey). It records every process's
  container, image and revision, and runs the contract check. Then it rebuilds and restarts Timekeeping
  alone and checks that the existing application's processes still run the same containers and images,
  that both of Timekeeping's were restarted, and that the contract check still holds. Then it does the
  same the other way round. There is no paired release. The first step that fails ends it, and the whole
  run, versions included, is written to `tmp/timekeeping-demo/deploys/<UTC time>.log`
  (`TIMEKEEPING_DEMO_RECORD_DIR` to keep it elsewhere). The contract tests of §12.3 prove each application
  against the shared schemas in its own CI; the contract check, `bin/timekeeping-demo contract-check`,
  proves the two running artifacts still keep them with each other. First, both read the same contract
  documents byte for byte (`packages/timekeeping_reservations/contracts/v1` in each image). Then
  `bin/rails timekeeping:contract_check` (`Timekeeping::ContractCheck`) runs in `miru-web`, signing in as
  the journey does. Over the handoff API, Timekeeping's copy of the ownership record must agree with this
  one. On both seeded businesses, an employee creates, edits and lists an entry (entry API), and an admin
  saves a draft with a line for it and deletes it (reservation API: prepare from `miru-web`, commit from
  `miru-jobs`); the candidates must leave the entry out and then offer it again. The time-entries report
  must show the edit and then drop the entry once the employee discards it (entry snapshot, delivered
  by `timekeeping-relay`). Each client checks every answer against its contract. Each run leaves one
  discarded entry and one discarded draft per business, with nothing reserved. `CHECK_WAIT` sets how
  long, in seconds, a check waits on a worker (default 60).
- **Relay paused (§13 item 5, §12.4).** `bin/timekeeping-demo relay-paused` runs while Timekeeping owns
  the entries. It stops `timekeeping-relay` and checks that it no longer runs. Then
  `bin/rails timekeeping:relay_paused:paused` (`Timekeeping::RelayPausedCheck`) runs in `miru-web`,
  signing in as the journey does. On both seeded businesses an employee creates an entry, and the
  employee's entry list shows it at once. The projection (`timesheet_entries`) must not hold the entry
  yet. The invoice candidates offer it at once, and an admin saves a draft with a line for it, which
  reserves it. The time-entries report must still leave it out. Then the script starts the relay again
  and runs `timekeeping:relay_paused:resumed`: the report must show the entry as written, while the draft
  still holds it. Then the admin deletes the draft and the employee discards the entry. If the
  projection already holds the entry while the relay should be stopped, the run fails, because it would
  prove nothing. Both halves name their writes after one run (`RUN`, set by the script). The relay is
  started again however the first half ends. A run that finishes leaves one discarded entry and one
  discarded draft per business, with nothing reserved. `CHECK_WAIT` sets how long, in seconds, a check
  waits on a worker (default 60).
- **Signals (§11.3).** Each of the existing application's two workers reads the other's alerts, so a
  stopped worker is still noticed: `invoice_operations` reads the local relay's lag (above 60 s for
  5 minutes), and `timekeeping_relay` reads the invoice operation ledger (an intent pending past 60 s, a
  commit or abort undelivered past 60 s). A stale-generation refusal while this application's ownership
  copy is open is reported as it happens, and so is a single-writer guard violation
  (`Timekeeping::SingleWriterWatch`): once entries have left the legacy owner, any statement from a
  process of the existing application (web, workers, rake, console) that writes `timesheet_entries`
  outside the projection consumer, named with the code that sent it. Every alert goes to `Rails.error`
  and to the log at error level, which is where the demo shows it.
  These alerts reach the existing application's log and not Sentry, because its `config/initializers/sentry.rb` leaves `config.rails.register_error_subscriber` unset on purpose: setting it would send every `Rails.error.report` in that application to Sentry in production, not only these alerts.
  `bin/timekeeping-demo compose exec miru-web bin/rails
  timekeeping:signals` prints each signal and exits 1 on an alert. Timekeeping reads its own
  (`app/services/signals.rb`): its relay's lag, read every 15 s on `timekeeping-relay`, the one worker it
  has; a stale-generation refusal while its copy is open; and a reconciliation difference its handoff API
  finds. They go to its log at error level, and to Sentry with the tag `timekeeping` once `SENTRY_DSN` is
  set, which the demo does not set. `bin/timekeeping-demo compose exec timekeeping-web bin/rails
  timekeeping:signals` reads them, and still works when the relay's worker is stopped.
- **The journey (§13 item 1).** `bin/timekeeping-demo journey` runs `bin/rails timekeeping:journey`
  (`Timekeeping::Journey`) inside `miru-web`, on a freshly seeded demo; it refuses once a handoff has
  begun. On both seeded businesses it signs in over the public API as the seeded users, with
  `MIRU_SEED_PASSWORD`. In each stage an employee creates and edits entries, editing the previous
  stage's entry too, and an admin or owner saves a direct and a grouped draft. Then it checks the
  reservations through the invoice candidates, the time-entries report (which waits for the relay) and
  each draft's PDF. It runs each handoff with its own task (first cutover, rollback, re-cutover), with a
  stage of new writes under every owner. Around each handoff it takes the financial snapshot before and
  after, and they must be identical. After each one it reads back every entry accepted so far, under
  any owner, as last written, along with every reservation, draft, report and PDF. The first check that
  fails exits 1. It does not resume: a handoff that stops leaves its journal for its own runner, and
  the next journey needs a reset. `JOURNEY_PDF=skip` leaves out the PDF downloads for a runtime with
  no Chromium; the demo's image has one. `JOURNEY_WAIT` sets how long, in seconds, a check waits on a
  worker (default 60).
- **Alternating writers (§12.4).** `bin/timekeeping-demo alternating-writers` runs
  `bin/rails timekeeping:alternating_writers` (`Timekeeping::AlternatingWriters`) inside `miru-web`, on a
  freshly seeded demo, like the journey; it refuses once a handoff has begun, and shares the journey's
  stages and handoffs (`Timekeeping::DemoHandoffs`). On both seeded businesses it writes a stage under each
  owner (legacy, timekeeping, monolith, timekeeping), with each handoff run by its own task in between, and
  the financial snapshot identical around each one. In every stage each writer of §1.3 writes, and from the
  second stage on each one writes an entry another writer wrote under the owner before the handoff. W6
  destroys the previous stage's agent, which detaches its entry while the previous stage's draft still
  holds it. W7 deletes that draft, which releases the entry. W1 web edits the previous stage's MCP entry,
  and W1 mobile the web one. W3 CLI edits the imported one, and W3a MCP (`miru.time.update` over `/mcp`)
  the CLI one. W2 bulk-moves the CLI and imported entries to another project of the same client, and
  bulk-discards the mobile one. Each writer also creates an entry of its own: W4 through a new agent's key,
  and W5 by importing an unbilled and a billed Harvest row. Last, W7 saves a draft holding the new agent
  entry. W1, W2, W3, W3a and W7 go over the public API, the CLI and MCP with a CLI session's token. The
  agents and their keys are made in process, because the existing application has no API for them. W5
  runs the importer as `imports:harvest_time_entries` does, and W6 destroys the agent through its model,
  since neither has an HTTP entry point. Every write still goes through the gateway. After each stage, and
  again after each handoff, every entry written so far must read back through the owner as last written
  (note, duration, project, agent, bill status, source), and a discarded one must not be found. The
  projection must catch up to the same, and the candidates must leave out the entry the current draft
  holds and offer every other kept, unbilled one. If the Copper Kettle Bakery's employee is on only one
  project, the run first adds a second project to the same client, before any handoff, for W2's moves.
  `CHECK_WAIT` sets how long, in seconds, a check waits on a worker (default 60). Like the journey, it does
  not resume, and the next run needs a reset.
- **Mail.** Development mail goes to `letter_opener`, under `tmp/letter_opener` in `miru-web`. `BROWSER=/bin/true`
  stops Launchy from looking for a browser the container does not have.
- **Reset.** `bin/timekeeping-demo compose down --volumes` deletes both databases and the journals. The next
  `up` reseeds. This is the "fresh demo reset" of §10.1: the seed builders refuse once a handoff has begun.

`spec/config/timekeeping_demo_runtime_spec.rb` checks these files as written: the images, the separate
databases and credentials, the dedicated workers (loading the demo's Solid Queue configuration), the
wiring and the script. It starts no container.
