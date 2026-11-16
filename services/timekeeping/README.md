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
| `app/services/outbox_redelivery.rb`, `lib/tasks/redelivery.rake` | The duplicate and reordered delivery of §13 item 6, sent on purpose: `bin/rails timekeeping:redeliver ENTRIES="<ids>"` resends the named entries' outbox snapshots through the relay's own call (`OutboxRelay#redeliver`, which posts a batch as `#run` does and takes, locks and marks nothing): each entry's newest first, in one batch, then each older one on its own, newest first, then all of them again in outbox order. Each receipt must be the one a consumer that upserts by version answers: the newest all applied, every other ignored. The first receipt that differs exits 1. It runs only while this copy says Timekeeping owns the entries with admission open, and refuses an entry with fewer than two snapshots. `bin/timekeeping-demo redelivery` runs it while the relay is stopped. |
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
bin/timekeeping-demo user-delete-refused     # the user-hard-delete proof (§12.4); after a cutover, then after a rollback
bin/timekeeping-demo aggregate-line          # the aggregate-line proof (§12.4, F3), with timekeeping-web stopped for its failures
bin/timekeeping-demo billing-handoff         # billing writes during a handoff (§12.4): the handoff waits for a paused one, then refuses them
bin/timekeeping-demo save-failures           # the save-failure rows of §9.3 (§12.4 failure injection): lost prepare answers, a crash, a rollback, replays
bin/timekeeping-demo reservation-failures    # the reservation-protocol rows of §9.3: wrong company, earlier operation unresolved, lost commit answer
bin/timekeeping-demo hard-delete             # §9.3's hard delete of a non-draft: a failed one changes nothing, a successful one keeps the edit lock until a successor
bin/timekeeping-demo stale-generation        # §9.3's stale generation: calls carrying another generation refused and changing nothing, retries to the current owner
bin/timekeeping-demo consumer-down           # §9.3's projection consumer down: entries listed and invoiced at once, the relay's deliveries refused, then its resend caught up
bin/timekeeping-demo redelivery              # §13 item 6's duplicate and reordered delivery: snapshots resent out of order and twice, only the newest applied
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
- **User hard delete refused (§12.4, §10.1).** `bin/timekeeping-demo user-delete-refused` runs while
  Timekeeping or the prepared application owns the entries; run it once after a cutover and once after a
  rollback. It asks `bin/rails timekeeping:user_delete_refused:relay` which service runs the current owner's
  relay: `timekeeping-relay` for Timekeeping, `miru-jobs` for the prepared application's local relay. It stops
  that service and checks that it no longer runs. Then `bin/rails timekeeping:user_delete_refused:paused`
  (`Timekeeping::UserDeleteRefusedCheck`) runs in `miru-web`. On both seeded businesses it makes a new
  employee on the business's billable project, with an agent of theirs, in process, as the alternating-writers
  driver makes its agents. That user creates their first entry over the public API, and their entry list
  shows it at once. The projection must not hold it yet. The super admin's `DELETE /api/v1/users/:id` must
  answer 422 with the handoff refusal. After it, the user, their agent and their entry must be as before,
  with no `super_admin_delete` audit row. The super admin is `SuperAdmin`'s address, made with the seeded
  password when the demo has none, and employed with no role in the first business, as token sign-in needs.
  Then the script starts the relay again and runs `timekeeping:user_delete_refused:resumed`: the projection
  must hold the entry under that user, the key to `users` holding. Then the user discards it. If the
  projection already holds the entry while the relay should be stopped, the run fails. All three steps name
  their writes after one run (`RUN`, set by the script), and the relay is started again however the first
  half ends. A run that finishes leaves, per business, the user, which cannot be deleted while the
  extraction is active, its agent and one discarded entry. Making a user queues its `HubspotIntegrationJob` on
  `default`, which the demo never starts (§11.1), so nothing is sent. `CHECK_WAIT` sets how long, in seconds,
  a check waits on a worker (default 60).
- **Aggregate line removed from a draft (§12.4, F3).** `bin/timekeeping-demo aggregate-line` runs while
  Timekeeping owns the entries, in three steps in `miru-web` (`Timekeeping::AggregateLineCheck`), all under one
  run name (`RUN`). On both seeded businesses, `bin/rails timekeeping:aggregate_line:held`: the employee creates
  entries X, Y and W, and the admin saves a draft with a direct line for X and a grouped line linking X and Y,
  and a second draft with a direct line for W. A save of the first draft that removes the grouped line and adds
  W is refused (F1, 422), and changes nothing. Then removing the grouped line keeps X reserved, because the
  direct line still references it, and releases Y; removing the direct line releases X; and both lines go back
  on, reserving X and Y again. The script then stops `timekeeping-web` and checks that it no longer runs.
  `timekeeping:aggregate_line:outage` first checks that the invoice candidates answer 503, as they read
  Timekeeping; if they answer, the step fails before it writes. Then a save removing the grouped line and a
  bulk delete of the draft (its hard destroy, §1.4) each answer 503, the draft keeps both lines, and the
  invoice operation ledger records both as failed. The script starts `timekeeping-web` again, waiting until it
  is healthy, and runs `timekeeping:aggregate_line:restored`: X, Y and W are still reserved, the ledger
  delivers both aborts, and a bulk delete then destroys the draft and releases X and Y together, while W stays
  with the second draft. Last, the admin deletes the second draft and the employee discards the three entries.
  Reservations are read where the invoice editor reads them, the candidates, which offer an entry exactly when
  nothing reserves it; the draft's lines are read from the existing application's invoice tables.
  `timekeeping-web` is started again however the outage step ends. A run that finishes leaves, per business,
  three discarded entries, one discarded draft and nothing reserved. The proof runs under the Timekeeping
  owner only: its failures come from stopping Timekeeping, and the prepared application has no separate
  process to stop. Under that owner, F3 is covered in process by `spec/requests/timekeeping/invoice_reservation_writes_spec.rb`
  ("under the monolith owner") and `spec/services/timekeeping/local_reservations_spec.rb`. `CHECK_WAIT` sets how long, in seconds, a check
  waits on a worker (default 60).
- **Billing writes during a handoff (§12.4, §10.1).** `bin/timekeeping-demo billing-handoff` runs under any owner
  with admission open, and runs the handoff that owner hands over with, which
  `bin/rails timekeeping:billing_handoff:handoff` (`Timekeeping::BillingHandoffCheck`) names: the first cutover from
  `legacy`, the rollback from `timekeeping`, the re-cutover from `monolith`. All four steps run in `miru-web` under one
  run name (`RUN`). `timekeeping:billing_handoff:paused` is the billing write: in one transaction, on both seeded
  businesses, a sent invoice of the run with a line item and an invoice tax, and a partial payment on it through the
  payment service the payments API uses. Each passes the billing-write fence, so the transaction holds the ownership
  row `FOR SHARE`, and it stays open. The script starts the handoff task meanwhile. The paused step waits until that
  handoff's step 1, the close's `FOR UPDATE` of the ownership row, is blocked by its own transaction
  (`pg_blocking_pids`), and checks that ownership still reads open at the old generation. Then the script stops
  `timekeeping-web` and releases the write, which commits; only then does the handoff close admission, and it stops
  at its next step, which closes Timekeeping's copy, for a resume. The script checks that it stopped and shows its
  output, kept under `tmp/timekeeping-demo/billing-handoff/`. With the handoff standing there,
  `timekeeping:billing_handoff:refused` checks that this copy is closed at the raised generation, and that the financial
  snapshot the handoff's journal holds, taken once its close drained the paused write, has the run's invoices, lines
  and taxes as they committed. On both businesses, over the public API as the admin, an invoice create with a line item
  and a tax, an update of the run's invoice changing its line's rate and its tax, and a payment on it each answer 503
  with the ownership-moving message, and no invoice, line-item, invoice-tax or payment row changes. Then the script
  starts `timekeeping-web` again, resumes the handoff to its end, and `timekeeping:billing_handoff:resumed` checks that
  the incoming owner holds the entries with admission open and that a payment on each run's invoice is accepted again.
  The steps pass what they need through `tmp/timekeeping/billing-handoff/<run>/` in the `miru_handoff_journals` volume:
  the run's state and the `admitted`, `waiting` and `release` markers. `timekeeping-web` is started again however the
  steps between end. If the paused write fails before its release it rolls back, and the handoff it held then runs on;
  a failed step otherwise leaves the handoff where it stands, for its task to resume or abort. A run that finishes
  leaves, per business, one sent invoice of the run with two partial payments, and the handoff done, so the demo has
  moved to the next owner. The handoff's step 1 waits at most 60 s (§10.1), which the script's steps fit in. `CHECK_WAIT`
  sets how long, in seconds, a step waits on another process (default 60). In process, the paused step is covered across
  connections by `spec/models/timekeeping/billing_handoff_paused_spec.rb`, the other steps by
  `spec/requests/timekeeping/billing_handoff_check_spec.rb`, and the fence itself by
  `spec/models/timekeeping/billing_write_admission_spec.rb` and `spec/requests/timekeeping/billing_write_fence_spec.rb`.
- **Save failures (§12.4 failure injection, §9.3).** `bin/timekeeping-demo save-failures` runs
  `bin/rails timekeeping:save_failures` (`Timekeeping::SaveFailuresCheck`) inside `miru-web`, in one step, while
  Timekeeping owns the entries with admission open. It covers the rows of §9.3 where an invoice save fails, or is
  replayed, after its prepare reached Timekeeping. On both seeded businesses the employee creates entries A, B, C and D
  over the public API. The admin saves a draft holding A, and its commit is delivered. Then:
  - **Prepare arrives after its operation is terminal, and the terminal-receipt row (§9.2 step 3).** The save's steps
    2-4 run again for its committed operation (`Timekeeping::InvoiceBoundary#perform`, as a resend of the same
    operation does): Timekeeping answers its `committed` receipt, the save returns the existing outcome, and the invoice
    change, which fails the check if it runs, does not run. Then the same replay with the intent forced `pending` fails
    with a retryable reconciliation error. The forced `pending` lasts only inside a transaction the check rolls back,
    so the invoice operation worker never sees it.
  - **Invoice transaction rolls back.** A save of B over the public API reuses the draft's number, so the invoice fails
    validation inside the invoice transaction, after its prepare reserved B: 422, the intent `failed`, no invoice, and
    the abort delivered from the ledger releases B. A replay of that `aborted` operation then fails.
  - **Lost response on prepare.** A save of C, run in process through `Timekeeping::InvoiceWrites`, whose provider sends
    each prepare to Timekeeping and then loses the answer as a read timeout: Timekeeping prepares it three times (the
    boundary's attempts, one operation), the save fails as retryable, its intent is `failed`, and the abort releases C.
  - **Crash after prepare, before the invoice commits.** A save of D runs in a child process that kills itself with
    SIGKILL inside the invoice transaction, after the invoice was written: the intent is still `pending`, there is no
    invoice, and D stays held. Once the save's 30 s time limit passes, recovery on `miru-jobs` records `failed` and the
    abort releases D.

  "Changed nothing" is read on both sides: the invoice and its lines, the invoice's ledger rows, and Timekeeping's own
  record of the entry (version, `locked`, `updated_at`). Reservations are read from the invoice candidates. A run that
  finishes leaves, per business, four discarded entries and one discarded draft. `CHECK_WAIT` sets how long, in
  seconds, a check waits on a worker (default 60; the crash's recovery takes about 35 s of it). The other rows of §9.3
  are proved elsewhere or not yet on the demo: Timekeeping down at prepare and F1 by the aggregate-line proof, relay
  paused by the relay-paused proof, the reservation-protocol rows by the reservation-failures proof below. In process,
  the rows this proof covers are pinned by
  `spec/services/timekeeping/invoice_boundary_spec.rb` and `spec/services/timekeeping/invoice_operation_worker_spec.rb`
  (under the monolith owner too, where a row applies to it), and the check itself by
  `spec/services/timekeeping/save_failures_check_spec.rb`.
- **Reservation failures (§12.4 failure injection, §9.3).** `bin/timekeeping-demo reservation-failures` covers the rows
  of §9.3 where Timekeeping refuses a prepare, or the answer to a commit is lost. It runs while Timekeeping owns the
  entries with admission open, in two steps in `miru-web` (`Timekeeping::ReservationFailuresCheck`). It stops
  `miru-jobs`, which runs the invoice operation worker, and runs `bin/rails timekeeping:reservation_failures:paused`.
  Then it starts `miru-jobs` again, however that step ends, and runs `timekeeping:reservation_failures:resumed`. On
  both seeded businesses the employee creates entries X, Y and W over the public API. Then:
  - **Prepare refused, wrong company (L8).** The admin saves an invoice naming the other business's W: 422 with
    "Time entry … belongs to another workspace, so the invoice was not saved.", the intent `failed`, no invoice, and W
    unchanged on Timekeeping and still offered to its own business.
  - **Prepare refused, earlier operation unresolved.** The admin saves a draft holding X. With the worker stopped its
    commit is not delivered, so Timekeeping still holds the draft's operation prepared. An update adding Y, run in
    process with Timekeeping unreachable, fails before its prepare is sent. Two more updates adding Y, one in process
    and one over the public API, each carry in `resolves` the outcome of the update before it, which Timekeeping
    never held. Timekeeping refuses both as `operation-unresolved`: the first fails as a retryable
    `operation_unresolved`, and the second answers 409 with the busy message. The draft still holds X alone.
  - **Lost response on commit.** One sweep of the invoice operation worker runs in process, through an owner that
    sends each commit and abort to Timekeeping and then loses the answer as a read timeout. Timekeeping answers the
    draft's commit `committed` and every abort `aborted`, and every one of them stays undelivered. The paused step
    keeps Timekeeping's record of X (version, `locked`, `updated_at`) in
    `tmp/timekeeping/reservation-failures/<run>/state.json`, in the `miru_handoff_journals` volume.
  - **Recovery, and the client's retry.** Once `miru-jobs` runs again, it delivers every operation of the run: commit
    again for the draft, and abort for each failed save. X is unchanged on Timekeeping, so the second commit changed
    nothing. The client retries the update adding Y over the public API, and it goes through. The draft is then
    deleted and the entries discarded.

  If the draft's commit is delivered during the paused step, the worker was running and the run fails. Keep the paused
  step under a minute: with `miru-jobs` stopped, nothing reads the ledger's alerts, and an outcome undelivered past
  60 s raises the §11.3 alert once `miru-jobs` is back, until it is delivered. `CHECK_WAIT` sets how long, in seconds,
  a check waits on a worker (default 60). The check itself is covered by
  `spec/services/timekeeping/reservation_failures_check_spec.rb`. The hard-delete proof below covers the last row of
  §9.3.
- **Hard delete of a non-draft (§12.4 failure injection, §9.3, §7.3, §13 item 6).** `bin/timekeeping-demo hard-delete`
  runs `bin/rails timekeeping:hard_delete` (`Timekeeping::HardDeleteCheck`) inside `miru-web`, in one step, while
  Timekeeping or the prepared application owns the entries with admission open; run it after a cutover, and after a
  rollback for the prepared application's own reservation table. Nothing is stopped or started: the failure is the
  one a user meets, a bulk delete (the hard destroy, §1.4) refused because the invoice has a recorded payment, inside
  the invoice transaction after the owner prepared it. On both seeded businesses the employee creates entries X and Y
  over the public API. The admin saves a draft holding each, which locks it (L1), and marks both sent, a non-draft
  save that keeps each entry and its lock, then records a payment of 1 on X's invoice. Then:
  - **A failed hard delete.** The bulk delete of X's invoice answers 422 "Some invoices could not be deleted because
    they have recorded payments.", naming it. The invoice, its line and its payment are as they were, the ledger
    records the destroy `failed` and delivers its abort, and X is unchanged on its owner (version, `locked`,
    `updated_at`): still left out of the candidates, and the employee's edit is still refused with "Cannot edit a
    locked timesheet entry. Please contact admin."
  - **A successful hard delete.** The bulk delete of Y's invoice answers 204, the invoice is gone, and the ledger
    records the destroy `succeeded` and delivers its commit. Y keeps its edit lock (still `locked` on its owner, and
    the employee's edit still refused), and the candidates offer it again (L3): the reservation is retained, carrying
    the deleted invoice as its owner.
  - **The successor.** The admin saves a draft holding Y, which is accepted: a retained reservation does not refuse a
    provisional successor. Once its commit is delivered the admin deletes the draft, which releases it (F2), and Y is
    unlocked and the employee's edit goes through. Had the successor's commit not removed the retained reservation,
    Y would still be locked. Then the employee discards Y.

  The lock is read twice: on the owner, through the entry reads under the current owner (`Timekeeping::EntryReads`),
  and as the employee meets it. A run that finishes leaves, per business, X's sent invoice with its payment, still
  holding X, which cannot be hard-deleted; one discarded draft; and Y discarded. `CHECK_WAIT` sets how long, in
  seconds, a check waits on a worker (default 60). The check is covered by
  `spec/requests/timekeeping/hard_delete_check_spec.rb`, which runs it whole under the prepared application, whose
  reservation table keeps the decision table's rules. Against `FakeTimekeeping`, which keeps none of them, it stops
  at the first edit lock it reads. The stale-generation proof below covers another row of §9.3.
- **Stale generation (§12.4 failure injection, §9.3, §13 item 6, §11.3).** `bin/timekeeping-demo stale-generation`
  runs `bin/rails timekeeping:stale_generation` (`Timekeeping::StaleGenerationCheck`) inside `miru-web`, in one step,
  while Timekeeping owns the entries with admission open. Nothing is stopped or started, and no handoff runs. A stale
  generation is what a queued job or a call already on its way carries once a handoff has raised the generation
  (§10.1). The check sends such calls to the running Timekeeping, each built as the gateway, the invoice reservation
  boundary or the invoice operation worker builds it, with only the generation changed: the one before the current
  generation, and for one call the one after it. On both seeded businesses:
  - **Never admitted.** The employee's create of entry X carrying the old generation, and then the next one, is
    refused 409 `stale-generation`, not retryable. So is the gateway's own send of that create under the old
    generation, which it answers as the public retryable 503 "Time entries are being moved between services, so
    nothing was saved. Try again in a minute." Timekeeping holds no X after any of them. The employee then retries
    over the public API: the gateway re-reads ownership, sends the create under the current generation, and
    Timekeeping holds exactly one X.
  - **Admitted.** The employee's update of X goes through under the current generation. Its retry with the same
    `Idempotency-Key` and the old generation is refused and changes nothing. Its retry under the current generation
    is answered the stored result, and X is unchanged (version, `locked`, `updated_at`): an admitted command never
    runs twice.
  - **Reservations.** The admin saves a draft holding X, and its commit is delivered. A prepare adding entry Y to the
    draft, carrying the old generation, is refused, and Y is still offered. A commit and an abort of the draft's
    committed operation, carrying the old generation, are refused too. The commit under the current generation is
    answered its stored `committed` receipt. X and Y on Timekeeping, and the draft's ledger rows, are unchanged. The
    admin then retries the save adding Y over the public API, and it goes through.

  Each refusal is also the §11.3 alert for a stale-generation refusal outside a handoff, on both sides. The check
  counts the existing application's own report of each refusal as it happens (one per call). Every refused call
  carries an `X-Request-Id` of the run, and the step's last line names them, so the command then finds Timekeeping's
  alert for each one in `timekeeping-web`'s log (`[<request id>] Timekeeping signal stale_generation: …`), and fails if
  one is missing. The step's output is kept under `tmp/timekeeping-demo/stale-generation/`. A run that finishes
  deletes its draft and discards X and Y. `CHECK_WAIT` sets how long, in seconds, a check waits on a worker (default
  60). The check is covered by `spec/services/timekeeping/stale_generation_check_spec.rb` against `FakeTimekeeping`,
  which refuses another generation before it reads a receipt, as Timekeeping's admission does. The consumer-down
  proof below covers the last row of §9.3.
- **Projection consumer down (§12.4 failure injection, §9.3).** `bin/timekeeping-demo consumer-down` runs while
  Timekeeping owns the entries with admission open. The row is "Projection consumer down | Same as relay paused |
  Relay retries; upsert by version". The consumer is the existing application's
  `POST /internal/v1/projection/entry_snapshots`, served by `miru-web`. Stopping `miru-web` would also stop the
  public API that the "same as relay paused" behaviour is checked through. So the command takes the consumer down
  as `timekeeping-relay` sees it, and nothing else changes. Inside that one container it adds a line to
  `/etc/hosts` that points `miru-web` at 127.0.0.1, where nothing listens. Each delivery is then refused at connect
  (`Errno::ECONNREFUSED`), the same error a consumer whose process is not running gives. `miru-web` and every other
  process keep running, and the relay keeps running too. A probe from the relay's container, against its own
  `EXISTING_APP_URL`, must reach the consumer before the run, be refused while it is down, and reach it again
  afterwards. The three steps run `bin/rails timekeeping:consumer_down:projected`, `:down` and `:restored`
  (`Timekeeping::ConsumerDownCheck`) inside `miru-web`, under one run name. On both seeded businesses:
  - **Projected** (consumer up). The employee creates entry X, and the projection holds it as Timekeeping does.
  - **Down.** The employee edits X and creates entry Y. The entry list shows both as written at once. The
    projection still holds X as it was before the edit, and holds no Y. The invoice candidates offer both at once.
    The admin saves a draft with a direct line for each, and the candidates then leave both out. Timekeeping now
    holds X at a later version. Five seconds later the projection is still unchanged, and the time-entries report,
    which reads the projection, still shows X as it was before the edit and no Y. That is "same as relay paused":
    the projection lags, with `locked` and the aggregates stale, while invoicing works at once. A projection that
    moves during this step fails the run.

    The command then requires at least two of the relay's deliveries to be refused in `timekeeping-relay`'s log
    (`relay: relay <id>: Errno::ECONNREFUSED: …`). Those are its retries, a batch every second, each rolled back
    unmarked. It also requires Timekeeping's `timekeeping:signals` to count outbox positions still undelivered.
    Then it removes the line. No container is restarted: every process keeps the container and image it had.
  - **Restored.** The same relay's next run delivers the backlog. The projection then holds X and Y exactly as
    Timekeeping does (version, note, duration, `locked`, `bill_status`), at the version that includes the edit and
    the draft's reservation, even though the outbox also held older snapshots of both. That is the upsert by
    version. The report shows both as written, and the candidates still leave both out. The admin deletes the draft,
    which releases both (F2), the employee discards X and Y, and the projection holds both discarded. Afterwards
    Timekeeping's signals count nothing undelivered.

  The consumer is brought back however the down step ends. A run that finishes leaves, per business, two discarded
  entries and one discarded draft, with nothing reserved. `CHECK_WAIT` sets how long, in seconds, a check waits on
  a worker (default 60). The check is covered by `spec/requests/timekeeping/consumer_down_check_spec.rb`, where the
  relay's deliveries land nowhere while the consumer is down. The consumer's tolerance of duplicated and reordered
  batches is pinned by its own spec, `spec/requests/timekeeping/entry_snapshots_spec.rb`, and shown on the demo by
  the redelivery proof below. Under the prepared application the relay and the consumer run in one
  `miru-jobs` process (`Timekeeping::LocalRelay`), so there is no consumer to take down on its own, and this proof
  runs only while Timekeeping owns the entries.
- **Duplicate and reordered delivery (§13 item 6, §5.4, §9.3).** `bin/timekeeping-demo redelivery` runs while
  Timekeeping owns the entries with admission open. The consumer upserts each snapshot by `(entry_id, version)` and
  ignores anything not newer, so a snapshot that arrives twice, or after a newer one, must change nothing. One relay
  delivers in outbox order, so on its own it never sends an older snapshot after a newer one. Here Timekeeping sends
  them out of order on purpose, through the relay's own call. The four steps run `bin/rails
  timekeeping:redelivery:projected`, `:held`, `:reordered` and `:duplicated` (`Timekeeping::RedeliveryCheck`) inside
  `miru-web`, under one run name. On both seeded businesses:
  - **Projected** (relay running). The employee creates entry X, and the projection holds it as Timekeeping does.
  - **Held.** The command stops `timekeeping-relay`. The employee edits X twice, and creates entry Y and edits it.
    The admin saves a draft with a direct line for each. Once the candidates leave both out and the draft's commit is
    delivered, Timekeeping holds both reserved at later versions and changes them no further. The projection still
    holds X as it was created, and no Y. A projection that moves fails the run. The step's last line names the
    entries (`redelivery: entries: <ids>`), and Timekeeping's signals must count positions undelivered.
  - **The resend**, in `timekeeping-web`: `bin/rails timekeeping:redeliver ENTRIES="<ids>"` (`OutboxRedelivery`).
    First each entry's newest snapshot, in one batch, which the consumer must apply, every one: the projection was
    behind on all of them. Then each older snapshot on its own, newest first, and then every snapshot of those
    entries again, in one batch. The consumer must ignore every one of those. It checks each receipt
    (`applied`, `ignored`) and exits 1 at the first that differs. It marks nothing in the outbox.
  - **Reordered** (relay still stopped). The projection holds X, an overwrite, and Y, an insert, exactly as
    Timekeeping does: version, note, duration, project, work date, `locked`, `bill_status` and `updated_at`. The
    time-entries report shows both as last written. Timekeeping's signals must count at least as many positions
    undelivered as before the resend, so the outbox still holds them for the relay.
  - **Duplicated.** The command starts the relay and waits until Timekeeping's signals count nothing undelivered.
    The relay has then sent every one of those snapshots a second time. The projection is still exactly as
    Timekeeping holds it, the report shows both as last written, and the candidates still leave both out. The admin
    deletes the draft, which releases both (F2), the employee discards X and Y, and the projection holds both
    discarded.

  The relay is started again however the steps in between end. The output is kept under
  `tmp/timekeeping-demo/redelivery/`. A run that finishes leaves, per business, two discarded entries and one
  discarded draft, with nothing reserved. `CHECK_WAIT` sets how long, in seconds, a check, and the command's wait for
  the relay, waits on a worker (default 60). Keep the relay's stop under five minutes, or Timekeeping's relay-lag
  alert (§11.3) fires and the command's read of the signals fails. The check is covered by
  `spec/requests/timekeeping/redelivery_check_spec.rb`, and the resend by Timekeeping's
  `spec/services/outbox_redelivery_spec.rb`, against a stand-in consumer that upserts by version.
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
  Under the timekeeping and monolith owners, W6 deletes the agent once the owner has detached its entries,
  while the projection may still name it until the relay delivers the detach. So the
  `timesheet_entries → agents` foreign key is dropped before cutover (`20261116120000`), like the two billing
  keys (§10.2 step 3), and a projected row naming a deleted agent reads as no agent.
- **Mail.** Development mail goes to `letter_opener`, under `tmp/letter_opener` in `miru-web`. `BROWSER=/bin/true`
  stops Launchy from looking for a browser the container does not have.
- **Reset.** `bin/timekeeping-demo compose down --volumes` deletes both databases and the journals. The next
  `up` reseeds. This is the "fresh demo reset" of §10.1: the seed builders refuse once a handoff has begun.

`spec/config/timekeeping_demo_runtime_spec.rb` checks these files as written: the images, the separate
databases and credentials, the dedicated workers (loading the demo's Solid Queue configuration), the
wiring and the script. It starts no container.
