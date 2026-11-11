# timekeeping_reservations

The shared library of `docs/architecture/timekeeping-soa.md` §11.1. Timekeeping, the write gateway and
the prepared rollback target all read it; nobody keeps a second copy.

Today it holds only the **contracts** (§5, §12.3). The reservation decision table (§7.2) comes with
the Timekeeping core lane and will be tested row by row here.

## Contracts, v1

JSON Schema 2020-12. All three files reference the shared definitions in `common.json`. Changes within
v1 are additive (§5.1).

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

`spec/contracts/timekeeping/` in the existing application:

- `schemas_spec.rb`: the schemas are valid, list the routes of §5, carry every `timesheet_entries`
  column and today's enum values, round-trip a float `duration` exactly, accept the design's own
  examples, and refuse what they should.
- `fake_timekeeping_spec.rb` and `fake_relay_spec.rb`: the fakes hold to the contracts, over HTTP.

Provider tests against these schemas run in Timekeeping's CI once the service exists (§12.3).
