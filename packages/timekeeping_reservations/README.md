# timekeeping_reservations

The shared library of `docs/architecture/timekeeping-soa.md` §11.1. Timekeeping (`services/timekeeping`), the
write gateway and the prepared rollback target all read it; nobody keeps a second copy.

It holds the **reservation decision table** (§7.2) and the **contracts** (§5, §12.3).

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
`timekeeping_reservations` and keeps the protocol in `timekeeping_reservation_operations`. The existing
application loads this file from `config/initializers/timekeeping.rb`.

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
