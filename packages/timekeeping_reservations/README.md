# timekeeping_reservations

The shared library of `docs/architecture/timekeeping-soa.md` §11.1. Timekeeping (`services/timekeeping`), the
write gateway and the prepared rollback target all read it; nobody keeps a second copy.

It holds the **reservation decision table** (§7.2), the **handoff state machine** over the ownership
record (§10.1, §10.5), and the **contracts** (§5, §12.3).

## The reservation rule

`lib/timekeeping_reservations.rb` is plain Ruby with no dependencies. Load it with
`require "timekeeping_reservations"` once this `lib/` is on the load path. It is pure: a provider
loads, under `SELECT … FOR UPDATE` (§9.4), the entries an operation asks for and every reservation
those entries and the invoice hold. It calls the rule and persists the reservations it gets back.

| Call | Returns |
|---|---|
| `prepare(operation, entries:, reservations:)` | `Prepared(reservations:)` with the added entries reserved provisionally, or `Refused(refusals:)` with one `Refusal(entry_id, reason)` per refused entry and nothing reserved |
| `commit(operation, reservations:)` | the reservations after the table's commit effect |
| `abort(operation, reservations:)` | the reservations without this operation's provisional ones |
| `locked?(entry_id, reservations)` | the projection's `locked`: any reservation with `edit_lock`, provisional and retained included (§7.1) |
| `selectable?(entry_id, reservations)` | candidate selection: no active and no provisional reservation; retained does not count (L3, L4) |

`TABLE` holds one row per row of §7.2, keyed by `[kind, invoice_state, relation]`, with the effect at
prepare and at commit. `RELATIONS` derives `added`, `kept` and `removed` (or `all`, for discard and
destroy) from the desired set and the entries the invoice holds. `REFUSALS` holds the two "any" rows
of §7.2 that refuse, in order: `not_found`, `wrong_company` (L8), `on_other_invoice` (F1).

The prepared application's provider is `Timekeeping::LocalReservations`
(`app/services/timekeeping/local_reservations.rb`, §10.2 step 4). It persists what the table decides in
`timekeeping_reservations` and keeps the protocol in `timekeeping_reservation_operations`. Its entry
store is `Timekeeping::LocalEntries` (`app/services/timekeeping/local_entries.rb`), over the prepared
application's own `timekeeping_entries`, which have Timekeeping's `entries` shape. Every entry whose
reservations a prepare, commit or abort changes is saved there as its next version, with an entry
snapshot that carries its derived `locked` and no audit row, as `ReservationProtocol` records
Timekeeping's. A prepare answers each entry of the desired set with the facts line-item validation
needs (`prepared_entry` in `reservation_api.json`: company, project, user, duration, work date, and the
version the prepare left it at), as `Timekeeping::ReservationClient::PreparedEntry`, the value the
`timekeeping` owner's client answers for the same entry. The gateway's
`monolith` owner, `Timekeeping::Gateway::Local` (`app/services/timekeeping/gateway/local.rb`), writes
those entries for the single-entry and bulk commands, the import batches and agent detach, under today's
`TimesheetEntry` rules, and `Timekeeping::EntryReads` reads them back for the entry API's own reads.
Invoice candidate selection under that owner reads them too, through `Timekeeping::LocalEntries#candidates`:
the same arguments and `Candidate` values as the entry client's `candidates`, selected with `selectable?`
as Timekeeping's `CandidateList` selects them. Under that owner the invoice reservation boundary prepares
through the provider, by way of `Timekeeping::LocalReservationClient`
(`app/services/timekeeping/local_reservation_client.rb`): it admits the prepare under the intent's
generation in its own transaction, as Timekeeping admits one under `X-Ownership-Generation`, and answers
as `Timekeeping::ReservationClient` does (`Prepared`, a `Receipt` with the contract's string status, or
the contract's problem raised), so the boundary runs the same save order under either owner. The invoice
operation worker delivers commit and abort to the provider through the same client, admitted the same
way and answered with the same `Receipt` (`not-found` for a commit of an operation never prepared), so
delivery reads either owner one way. During a handoff out of that owner, the client also admits the
settle step's commit or abort carrying the old generation (§10.5 step 2, `Timekeeping::Ownership#settling?`),
only for an operation the provider registered, as Timekeeping's `ReservationProtocol` does. An entry change there records its audit row and its
entry snapshot through `Timekeeping::LocalEntryChange`, into the prepared application's outbox
(`timekeeping_outbox_snapshots`, Timekeeping's `outbox_snapshots` shape), and `Timekeeping::LocalRelay`
drains that outbox into `timesheet_entries` through the projection consumer, on its own
`timekeeping_relay` queue (`Timekeeping::LocalRelayJob`). The existing application loads this file from
`config/initializers/timekeeping.rb`.

A rollback fills those tables from the checkpoint taken out of Timekeeping
(`Timekeeping::HandoffClient#take_checkpoint`). `Timekeeping::CheckpointLoad`
(`app/services/timekeeping/checkpoint_load.rb`, §10.5 steps 4 and 5) runs that load. It runs only while the
existing application's copy of the ownership record is `frozen` under owner `timekeeping` at the
handoff's generation (`Timekeeping::Ownership.lock_frozen!`). It loads only into empty tables
(`AlreadyLoaded` otherwise). In one transaction it copies every part as carried: entries, committed
reservations, audit rows with their ids, terminal operation receipts and idempotency receipts. It then
sets the entry and audit sequences above the highest carried ids, and never moves them back (§10.3). It
writes no outbox snapshot: freeze already drained Timekeeping's outbox into the projection, at the
versions the checkpoint carries. A checkpoint that does not hold together is refused whole as
`Refused`, with what each check found.

`Timekeeping::RollbackReconcile` (`app/services/timekeeping/rollback_reconcile.rb`, §10.5 step 6) then
compares the loaded tables with the same checkpoint, under the same guard, and writes nothing. Every
check is exact: entries (every column by id, `version` and the derived `locked` included), each
entry's reservations, audit rows by id, operation receipts by `invoice_id/operation_id` and
idempotency receipts by `company_id/key`. It also runs the first cutover's checks of the existing
application's tables (`Timekeeping::CheckpointReconcile.differences`): kept invoices' lines against
the active reservations, `timesheet_entries` against the carried entries, and money by financial
snapshot. Any difference raises `CheckpointReconcile::Differs`, and the handoff is aborted.

`Timekeeping::Rollback` (`app/services/timekeeping/rollback.rb`, §10.2 step 6, §10.5) is the handoff tool
that runs those steps in order, as `Timekeeping::FirstCutover` runs the first cutover's: close this
application's copy of the ownership record, then Timekeeping's; settle (Timekeeping, the outgoing owner,
applies the old generation's commit and abort while its copy is closed); freeze both; wait for
Timekeeping's relay to drain its outbox into `timesheet_entries`; take the checkpoint, load it and
reconcile it; then flip this copy, the incoming owner, first and Timekeeping's second. It resumes from
where the two copies stand. The take is a read of a frozen Timekeeping, so a resumed transfer takes it
again, and a load that already ran (`AlreadyLoaded`) goes on to reconcile. A take refused as
`checkpoint-unsettled`, a load refused, or a reconcile difference aborts the handoff on both copies;
anything else leaves them fenced for a resume or `#abort!`. An abort leaves the prepared tables as the
load left them: a later rollback reconciles them against Timekeeping as it then stands, and aborts on
any write Timekeeping took since, so it never flips onto them unreconciled.

The re-cutover (`monolith` → `timekeeping`, §10.2 step 6) starts from the other side.
`Timekeeping::LocalCheckpoint` (`app/services/timekeeping/local_checkpoint.rb`, §10.5 step 4) takes the
checkpoint out of the prepared tables, with the same parts and forms as the rollback's take out of
Timekeeping (`handoff_api.json#/$defs/taken_checkpoint`). It runs only while this application's copy is
`frozen` under owner `monolith` at the handoff's generation, refuses as `Unsettled` while a provisional
reservation or a prepared operation is left, and writes nothing. It reads those tables through
`Timekeeping::PreparedRows`, the same reader `Timekeeping::RollbackReconcile` compares against, so the
two directions read one rendering.

Timekeeping's provider is `ReservationProtocol` (`services/timekeeping/app/services/reservation_protocol.rb`),
behind the reservation API's three endpoints. It keeps the same protocol on tables with the same shape,
`reservations` and `reservation_operations`, so a checkpoint carries reservations and receipts either way
unchanged (§10.5 step 4).

Receipts, generations and the one-unresolved-operation rule belong to the protocol (§5.3), so they are
not in the table. Prepare, commit and abort are idempotent on their own anyway: applying one twice
gives the same reservations.

### Choices the design left open

- **Prepare checks only the entries the operation adds.** Kept and removed entries are already held
  by this invoice, so they were checked when they were added.
- **A retained reservation of the same invoice** is succeeded like any other. If a non-draft drops an
  entry (retained) and later adds it back, the entry becomes active again with the lock of the save
  that added it.
- **The successor's lock replaces the retained one.** §7.2 says commit "succeeds and removes the old
  one", so a non-draft that takes over an entry retained with `edit_lock` leaves it with no lock.
  Today that entry stays locked, because nothing unlocks it. This follows the table as written.
- **Commit of an entry its operation never prepared** raises `ProtocolError`. The provider answers an
  unprepared operation (`404`, see below) before it reaches the table.

## The handoff state machine

`lib/timekeeping_reservations/handoff.rb` (`TimekeepingReservations::Handoff`, loaded with the rule) is
the one copy of the handoff's steps. §10.1 keeps a copy of the ownership record in each database; both
fences move theirs through these steps, so the copies cannot follow different rules:
`Timekeeping::HandoffFence` in the existing application and `HandoffFence` in `services/timekeeping`.

| Step | From | To | Also changes |
|---|---|---|---|
| `close` | `open` | `closed` | raises the generation |
| `freeze` | `closed` | `frozen` | — |
| `flip` | `frozen` | `open` | the owner, to its one successor (`SUCCESSORS`: legacy → timekeeping → monolith → timekeeping) |
| `abort` | `closed`, `frozen` | `open` | — (the raised generation stays) |

`STEPS.fetch(name).apply(record, generation:)` returns the attributes to write, or raises `OutOfStep`
unless the record is at `generation` in one of the step's states. It is pure: each fence locks its
record, applies the step and persists the result, and adds its own checks (the existing application's
freeze waits for settle). `spec/handoff_spec.rb` tests it once.

## Contracts, v1

JSON Schema 2020-12. All three files reference the shared definitions in `common.json`. Changes within
v1 are additive (§5.1).

The existing application reads them at run time through `Timekeeping::Contracts`
(`app/services/timekeeping/contracts.rb`), and so do the consumer-side fakes. The projection endpoint
(`Timekeeping::EntrySnapshotsController`) validates every delivery against `entry_snapshot.json` before
`Timekeeping::ProjectionConsumer` applies it.

| File | Contract | Provider | Consumer | Consumer-side fake |
|---|---|---|---|---|
| `contracts/v1/entry_api.json` | Entry API (§5.2) and the user token (§6.1) | Timekeeping | Write gateway | `TimekeepingContracts::FakeTimekeeping` |
| `contracts/v1/reservation_api.json` | Prepare, commit, abort (§5.3) | Timekeeping | Invoice reservation boundary, invoice operation worker | `TimekeepingContracts::FakeTimekeeping` |
| `contracts/v1/entry_snapshot.json` | Entry snapshot event and its delivery (§5.4) | Timekeeping relay | Projection consumer | `TimekeepingContracts::FakeRelay` |
| `contracts/v1/handoff_api.json` | Timekeeping's side of the handoff procedure (§10.1, §10.5): its copy of the ownership record, the relay's progress, the fence steps, the first cutover's checkpoint load and reconcile, and the rollback's checkpoint taken out of Timekeeping | Timekeeping | The handoff tools, `Timekeeping::FirstCutover` and `Timekeeping::Rollback`, through `Timekeeping::HandoffClient` | `TimekeepingContracts::FakeHandoff` |
| `contracts/v1/common.json` | Entry, problem types, ids, generation, duration | — | — | — |

Each contract file carries two extensions that JSON Schema ignores:

- `x-operations`: every route, with its method, whether it mutates, and the `$defs` of its request
  body or query and of each success response. Any non-2xx answer is a `common.json#/$defs/problem`.
- `x-headers`: the headers every call carries, and the ones a mutating call adds (§5.1).

### Choices the design left open

- **Problem types** are `https://contracts.timekeeping.internal/problems/<slug>`; the slugs are the enum
  in `common.json#/$defs/problem_type`.
- **Refusal reasons** at prepare are `on_other_invoice` (F1), `wrong_company` (L8) and `not_found`
  (§5.3: the prepare response is authoritative for existence).
- **Reservation API idempotency** is by `(invoice_id, operation_id)` (§5.3), so its `Idempotency-Key`
  header carries the `operation_id`. The body's `generation` must equal `X-Ownership-Generation`.
- **A commit of an operation that was never prepared** answers `404 not-found`. An abort of one is a
  no-op that still leaves an `aborted` receipt (§9.3).
- **Tokens** are HS256 JWTs signed with the shared token key, 60 s TTL. The user token's audience is
  `timekeeping`. The relay signs a service token, audience `projection`, for the projection endpoint.
- **Candidate selection** takes the client's kept `project_ids`, resolved by the gateway as
  `GenerateInvoice::NewLineItemsService` resolves them today, and the existing filters as `user_ids`,
  `from`, `to`, `exclude_ids` and `search_term`.
- **A snapshot delivery** answers `{ applied, ignored }`. A 2xx means the whole batch is durable.
- **The handoff tool reaches Timekeeping over HTTP** (`handoff_api.json`), as the two applications share
  no database (§11.2). It signs a service token, audience `handoff`, subject
  `service:timekeeping-handoff`; a user token or the relay's is refused. Its calls carry
  `X-Ownership-Generation`, which must equal the body's `generation`, and no `Idempotency-Key`: every
  step names the generation and state it expects, so a replay is `409 out-of-step` and changes
  nothing; a second load is `409 already-loaded`; reconcile writes nothing. A step whose lock waits
  out the admitted calls is a retryable `503 drain-timeout`. A load that does not hold together is
  `422 checkpoint-refused`, and a reconcile that finds a difference `409 checkpoint-differs`, each
  listing what every failed check found in the problem's `lists` extension.

## Tests

`spec/timekeeping_reservations_spec.rb` here tests the decision table row by row, once (§12.3). It
also checks that the table has exactly one row per kind, invoice state and relation, and that its
kinds, invoice states and refusal reasons are the reservation contract's. Run it from the repository
root with `bundle exec rspec packages/timekeeping_reservations/spec`. `bin/parallel_test`, which CI runs,
includes every `packages/*/spec` by default.

`spec/contracts/timekeeping/` in the existing application:

- `schemas_spec.rb`: the schemas are valid, list the routes of §5, carry every `timesheet_entries`
  column and today's enum values, round-trip a float `duration` exactly, accept the design's own
  examples, and refuse what they should.
- `fake_timekeeping_spec.rb` and `fake_relay_spec.rb`: the fakes hold to the contracts, over HTTP.

Provider tests against these schemas run in Timekeeping's own suite (`services/timekeeping/spec`),
through `services/timekeeping/spec/support/contracts.rb` (§12.3).
