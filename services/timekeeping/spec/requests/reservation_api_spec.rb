# frozen_string_literal: true

require "rails_helper"

# The reservation API (§5.3), provider side (§12.3): prepare, commit and
# abort of one invoice operation, admitted under the carried generation
# (§10.1), decided by the shared decision table (§7.2, tested row by row in
# its package), and kept to the protocol: terminal receipts per (invoice,
# operation), at most one unresolved operation per invoice, and an abort of
# an unknown operation that still leaves a receipt (§9.3). Every entry whose
# reservations change gets its next version and an outbox snapshot that
# carries the derived `locked` (§5.4).
RSpec.describe "Reservation API" do
  let(:fork_and_leaf) { 1 }
  let(:copper_kettle) { 2 }
  let(:generation) { 3 }
  let(:invoice_id) { 501 }
  let(:operation_id) { SecureRandom.uuid }

  before { Ownership.create!(generation:, owner: "timekeeping", state: "open") }

  def body = JSON.parse(response.body)

  # The system-actor token the existing application's ReservationClient signs.
  def mutating_headers(company_id: fork_and_leaf, key: nil, carried: generation, operation: operation_id)
    entry_api_headers(company_id:, sub: "system", role: nil, actor: { "type" => "system", "agent_id" => nil }, writer: "invoice")
      .merge("Idempotency-Key" => key || operation, "X-Ownership-Generation" => carried.to_s, "Content-Type" => "application/json")
  end

  def path(name, invoice: invoice_id, operation: operation_id)
    "/internal/v1/invoices/#{invoice}/operations/#{operation}/#{name}"
  end

  def prepare_body(entry_ids, kind: "save", invoice_state: "draft", company_id: fork_and_leaf, resolves: nil)
    { "company_id" => company_id, "generation" => generation, "kind" => kind, "invoice_state" => invoice_state,
      "entry_ids" => entry_ids, "resolves" => resolves }
  end

  def prepare(entry_ids, invoice: invoice_id, operation: operation_id, headers: {}, **body)
    post path("prepare", invoice:, operation:), params: JSON.generate(prepare_body(entry_ids, **body)),
      headers: mutating_headers(operation:, **headers)
  end

  def resolve(name, invoice: invoice_id, operation: operation_id, body: { "generation" => generation }, **headers)
    post path(name, invoice:, operation:), params: JSON.generate(body), headers: mutating_headers(operation:, **headers)
  end

  def commit(**) = resolve("commit", **)
  def abort_operation(**) = resolve("abort", **)

  def expect_answer(status, pointer)
    expect(response).to have_http_status(status)
    expect(contract_errors("reservation_api", pointer, body)).to be_empty
  end

  def expect_problem(status, slug)
    expect(response).to have_http_status(status)
    expect(response.media_type).to eq("application/problem+json")
    expect(body).to include("type" => "https://contracts.timekeeping.internal/problems/#{slug}", "status" => status)
    expect(contract_errors("common", "#/$defs/problem", body)).to be_empty
  end

  # Each entry's reservations as [invoice, state, disposition, edit_lock].
  def holdings(entry)
    entry.reservations.reload.order(:id).map { |row| [row.invoice_id, row.state, row.disposition, row.edit_lock] }
  end

  def expect_nothing_written(*entries)
    entries.each { |entry| expect(entry.reload.version).to eq(1) }
    expect([OutboxSnapshot.count, ReservationOperation.count]).to eq([0, 0])
  end

  describe "prepare" do
    it "reserves a draft's added entries provisionally with the edit lock, and answers their facts as the contract states it" do
      entry = entry!(company_id: fork_and_leaf, project_id: 9, user_id: 3, duration: 479.99999)

      prepare([entry.id])

      expect_answer(:ok, "#/$defs/prepare_response")
      expect(body).to eq(
        "status" => "prepared",
        "entries" => [{ "id" => entry.id, "company_id" => fork_and_leaf, "project_id" => 9, "user_id" => 3,
                        "duration" => 479.99999, "work_date" => "2026-11-02", "version" => 2 }]
      )
      expect(holdings(entry)).to eq([[invoice_id, "provisional", "active", true]])
      expect(entry.reservations.sole.operation_id).to eq(operation_id)
      expect(ReservationOperation.sole).to have_attributes(
        invoice_id:, operation_id:, company_id: fork_and_leaf, kind: "save", invoice_state: "draft",
        entry_ids: [entry.id], state: "prepared"
      )
    end

    it "gives each reserved entry its next version and a snapshot carrying locked, with no audit row (§5.4)" do
      entry = entry!(company_id: fork_and_leaf)
      updated_at = entry.updated_at

      prepare([entry.id])

      entry.reload
      expect(entry.version).to eq(2)
      expect(entry.updated_at).to be > updated_at
      snapshot = entry.outbox_snapshots.sole.snapshot
      expect(snapshot).to eq(OutboxSnapshot.of(entry))
      expect(snapshot).to include("version" => 2)
      expect(snapshot.dig("data", "locked")).to be(true)
      expect(contract_errors("entry_snapshot", "#/$defs/entry_snapshot", snapshot)).to be_empty
      expect(entry.outbox_snapshots.sole.request_id).to eq("req-#{fork_and_leaf}")
      expect(EntryAudit.count).to eq(0)
    end

    it "reserves a non-draft's added entries without the lock, and keeps updated_at, as locked does not change (L1)" do
      entry = entry!(company_id: fork_and_leaf)
      updated_at = entry.updated_at

      prepare([entry.id], invoice_state: "non_draft")

      expect_answer(:ok, "#/$defs/prepare_response")
      expect(holdings(entry)).to eq([[invoice_id, "provisional", "active", false]])
      expect(entry.reload).to have_attributes(version: 2, updated_at:)
      expect(entry.outbox_snapshots.sole.snapshot.dig("data", "locked")).to be(false)
    end

    it "answers every entry of the desired set, kept ones included, and changes only the added ones" do
      kept, added = entry!(company_id: fork_and_leaf), entry!(company_id: fork_and_leaf)
      reservation!(kept, invoice_id:)

      prepare([added.id, kept.id])

      expect_answer(:ok, "#/$defs/prepare_response")
      expect(body.fetch("entries").pluck("id", "version")).to eq([[added.id, 2], [kept.id, 1]])
      expect(holdings(kept)).to eq([[invoice_id, "committed", "active", true]])
    end

    it "lets a discarded entry be prepared: prepare is authoritative for existence, not for being kept" do
      entry = entry!(company_id: fork_and_leaf, discarded_at: Time.current)

      prepare([entry.id])

      expect_answer(:ok, "#/$defs/prepare_response")
    end

    describe "refusals (F1, L8, §5.3)" do
      it "refuses an entry another kept invoice holds active, with nothing reserved or written (F1)" do
        held = entry!(company_id: fork_and_leaf)
        reservation!(held, invoice_id: invoice_id + 1)
        free = entry!(company_id: fork_and_leaf)

        prepare([free.id, held.id])

        expect_problem(409, "reservation-refused")
        expect(body).to include("retryable" => false, "refused" => [{ "entry_id" => held.id, "reason" => "on_other_invoice" }])
        expect(holdings(free)).to be_empty
        expect(free.reload.version).to eq(1)
        expect([OutboxSnapshot.count, ReservationOperation.count]).to eq([0, 0])
      end

      it "refuses an entry another operation holds provisionally" do
        entry = entry!(company_id: fork_and_leaf)
        reservation!(entry, invoice_id: invoice_id + 1, state: "provisional")

        prepare([entry.id])

        expect_problem(409, "reservation-refused")
        expect(body.fetch("refused")).to eq([{ "entry_id" => entry.id, "reason" => "on_other_invoice" }])
      end

      it "refuses another company's entry as wrong_company and a missing one as not_found, each listed (L8)" do
        theirs = entry!(company_id: copper_kettle)

        prepare([theirs.id, 999_999])

        expect_problem(409, "reservation-refused")
        expect(body.fetch("refused")).to eq([
          { "entry_id" => theirs.id, "reason" => "wrong_company" },
          { "entry_id" => 999_999, "reason" => "not_found" }
        ])
        expect_nothing_written(theirs)
      end

      it "prepares an entry another invoice holds only as retained, and keeps the retained one while provisional (§7.1)" do
        entry = entry!(company_id: fork_and_leaf)
        reservation!(entry, invoice_id: invoice_id + 1, disposition: "retained")

        prepare([entry.id])

        expect_answer(:ok, "#/$defs/prepare_response")
        expect(holdings(entry)).to eq([[invoice_id + 1, "committed", "retained", true], [invoice_id, "provisional", "active", true]])
      end
    end

    describe "replays (§5.3, §9.3)" do
      it "answers the same body for the same operation again without a second change" do
        entry = entry!(company_id: fork_and_leaf)
        prepare([entry.id])
        first = body

        prepare([entry.id])

        expect_answer(:ok, "#/$defs/prepare_response")
        expect(body).to eq(first)
        expect(entry.reload.version).to eq(2)
        expect([OutboxSnapshot.count, Reservation.count, ReservationOperation.count]).to eq([1, 1, 1])
      end

      it "refuses another body for an operation already prepared as idempotency-conflict" do
        first, second = entry!(company_id: fork_and_leaf), entry!(company_id: fork_and_leaf)
        prepare([first.id])

        prepare([first.id, second.id])

        expect_problem(409, "idempotency-conflict")
        expect(holdings(second)).to be_empty
      end

      it "answers the stored receipt for a prepare that arrives after its operation is terminal, and changes nothing" do
        entry = entry!(company_id: fork_and_leaf)
        prepare([entry.id])
        commit

        prepare([entry.id])

        expect_answer(:ok, "#/$defs/prepare_response")
        expect(body).to eq("status" => "committed")
        expect(entry.reload.version).to eq(3)
      end
    end

    describe "one unresolved operation per invoice (§5.3)" do
      let(:earlier) { SecureRandom.uuid }

      it "refuses a new operation while an earlier one is unresolved, retryably, with nothing written" do
        entry = entry!(company_id: fork_and_leaf)
        prepare([entry.id], operation: earlier)

        prepare([entry.id])

        expect_problem(409, "operation-unresolved")
        expect(body).to include("retryable" => true)
        expect(ReservationOperation.pluck(:operation_id)).to eq([earlier])
      end

      it "refuses it too when resolves names another operation" do
        prepare([entry!(company_id: fork_and_leaf).id], operation: earlier)

        prepare([], resolves: { "operation_id" => SecureRandom.uuid, "outcome" => "aborted" })

        expect_problem(409, "operation-unresolved")
      end

      it "applies the earlier operation's outcome that resolves carries, then prepares" do
        first, second = entry!(company_id: fork_and_leaf), entry!(company_id: fork_and_leaf)
        prepare([first.id], operation: earlier)

        prepare([first.id, second.id], resolves: { "operation_id" => earlier, "outcome" => "committed" })

        expect_answer(:ok, "#/$defs/prepare_response")
        expect(ReservationOperation.order(:id).pluck(:operation_id, :state)).to eq([[earlier, "committed"], [operation_id, "prepared"]])
        expect(holdings(first)).to eq([[invoice_id, "committed", "active", true]])
        expect(holdings(second)).to eq([[invoice_id, "provisional", "active", true]])
      end

      it "keeps the earlier outcome resolves carried even when the new prepare is refused" do
        first, held = entry!(company_id: fork_and_leaf), entry!(company_id: fork_and_leaf)
        reservation!(held, invoice_id: invoice_id + 1)
        prepare([first.id], operation: earlier)

        prepare([held.id], resolves: { "operation_id" => earlier, "outcome" => "aborted" })

        expect_problem(409, "reservation-refused")
        expect(ReservationOperation.sole).to have_attributes(operation_id: earlier, state: "aborted")
        expect(holdings(first)).to be_empty
      end
    end
  end

  describe "commit" do
    it "makes a draft's desired set its reservations: added active and locked, kept re-locked, removed released (L1, L4, F3)" do
      added, kept, removed = entry!(company_id: fork_and_leaf), entry!(company_id: fork_and_leaf), entry!(company_id: fork_and_leaf)
      reservation!(kept, invoice_id:, edit_lock: false)
      reservation!(removed, invoice_id:)
      prepare([added.id, kept.id])

      commit

      expect_answer(:ok, "#/$defs/terminal_receipt")
      expect(body).to eq("status" => "committed")
      expect(holdings(added)).to eq([[invoice_id, "committed", "active", true]])
      expect(holdings(kept)).to eq([[invoice_id, "committed", "active", true]])
      expect(holdings(removed)).to be_empty
      expect([added, kept, removed].map { |entry| entry.reload.version }).to eq([3, 2, 2])
      expect(removed.outbox_snapshots.sole.snapshot.dig("data", "locked")).to be(false)
      expect(ReservationOperation.sole.state).to eq("committed")
    end

    it "retains a non-draft's removed entries, keeping their lock (L4)" do
      removed = entry!(company_id: fork_and_leaf)
      reservation!(removed, invoice_id:)
      prepare([], invoice_state: "non_draft")

      commit

      expect(holdings(removed)).to eq([[invoice_id, "committed", "retained", true]])
      expect(removed.reload.version).to eq(2)
    end

    it "succeeds a retained reservation of another invoice and removes it (§7.1)" do
      entry = entry!(company_id: fork_and_leaf)
      reservation!(entry, invoice_id: invoice_id + 1, disposition: "retained")
      prepare([entry.id])

      commit

      expect(holdings(entry)).to eq([[invoice_id, "committed", "active", true]])
    end

    {
      %w[discard draft] => [], # F2: today the entry stays locked (K2)
      %w[discard non_draft] => [["committed", "retained", true]], # L3
      %w[destroy draft] => [], # K7; F3 for linked entries
      %w[destroy non_draft] => [["committed", "retained", true]] # K7: the reservation carries the owner
    }.each do |(kind, invoice_state), expected|
      it "applies #{kind} of a #{invoice_state} invoice to every entry it holds" do
        entry = entry!(company_id: fork_and_leaf)
        reservation!(entry, invoice_id:)
        prepare([], kind:, invoice_state:)

        commit

        expect_answer(:ok, "#/$defs/terminal_receipt")
        expect(holdings(entry)).to eq(expected.map { |held| [invoice_id, *held] })
      end
    end

    it "answers the stored receipt again without a second change, and committed to a later abort" do
      entry = entry!(company_id: fork_and_leaf)
      prepare([entry.id])
      commit

      commit
      expect(body).to eq("status" => "committed")
      abort_operation
      expect(body).to eq("status" => "committed")

      expect(entry.reload.version).to eq(3)
      expect(holdings(entry)).to eq([[invoice_id, "committed", "active", true]])
    end

    it "answers not-found for an operation never prepared, and writes nothing" do
      commit

      expect_problem(404, "not-found")
      expect(ReservationOperation.count).to eq(0)
    end
  end

  describe "abort" do
    it "drops only this operation's provisional reservations and keeps what the invoice had committed" do
      added, kept = entry!(company_id: fork_and_leaf), entry!(company_id: fork_and_leaf)
      reservation!(kept, invoice_id:)
      prepare([added.id, kept.id])

      abort_operation

      expect_answer(:ok, "#/$defs/terminal_receipt")
      expect(body).to eq("status" => "aborted")
      expect(holdings(added)).to be_empty
      expect(holdings(kept)).to eq([[invoice_id, "committed", "active", true]])
      expect(added.reload.version).to eq(3)
      expect(kept.reload.version).to eq(1)
      expect(ReservationOperation.sole.state).to eq("aborted")
    end

    it "leaves the retained reservation a provisional successor waited on untouched" do
      entry = entry!(company_id: fork_and_leaf)
      reservation!(entry, invoice_id: invoice_id + 1, disposition: "retained")
      prepare([entry.id])

      abort_operation

      expect(holdings(entry)).to eq([[invoice_id + 1, "committed", "retained", true]])
    end

    it "records an aborted receipt for an operation never prepared, so its late prepare changes nothing (§9.3)" do
      entry = entry!(company_id: fork_and_leaf)

      abort_operation

      expect_answer(:ok, "#/$defs/terminal_receipt")
      expect(body).to eq("status" => "aborted")
      expect(ReservationOperation.sole).to have_attributes(state: "aborted", company_id: fork_and_leaf, kind: nil)

      prepare([entry.id])

      expect(body).to eq("status" => "aborted")
      expect_nothing_written_but_the_receipt(entry)
    end

    it "answers aborted to a later commit of the same operation" do
      abort_operation

      commit

      expect_answer(:ok, "#/$defs/terminal_receipt")
      expect(body).to eq("status" => "aborted")
    end

    def expect_nothing_written_but_the_receipt(entry)
      expect(entry.reload.version).to eq(1)
      expect([OutboxSnapshot.count, Reservation.count, ReservationOperation.count]).to eq([0, 0, 1])
    end
  end

  describe "tenant isolation (§6.3)" do
    it "answers another company's call naming the invoice as not-found, for each of the three" do
      entry = entry!(company_id: fork_and_leaf)
      prepare([entry.id])

      prepare([], headers: { company_id: copper_kettle }, company_id: copper_kettle, operation: SecureRandom.uuid)
      expect_problem(404, "not-found")
      commit(company_id: copper_kettle)
      expect_problem(404, "not-found")
      abort_operation(company_id: copper_kettle)
      expect_problem(404, "not-found")

      expect(holdings(entry)).to eq([[invoice_id, "provisional", "active", true]])
      expect(ReservationOperation.sole.state).to eq("prepared")
    end

    it "refuses a body naming another company than the token's as forbidden" do
      entry = entry!(company_id: copper_kettle)

      prepare([entry.id], company_id: copper_kettle)

      expect_problem(403, "forbidden")
      expect_nothing_written(entry)
    end
  end

  describe "admission (§10.1)" do
    it "refuses a stale generation for each of the three, with nothing written" do
      entry = entry!(company_id: fork_and_leaf)

      post path("prepare"), params: JSON.generate(prepare_body([entry.id]).merge("generation" => generation - 1)),
        headers: mutating_headers(carried: generation - 1)
      expect_problem(409, "stale-generation")
      commit(body: { "generation" => generation - 1 }, carried: generation - 1)
      expect_problem(409, "stale-generation")
      abort_operation(body: { "generation" => generation - 1 }, carried: generation - 1)
      expect_problem(409, "stale-generation")

      expect_nothing_written(entry)
    end

    it "refuses retryably while a handoff has admission closed" do
      entry = entry!(company_id: fork_and_leaf)
      Ownership.current.update!(state: "closed")

      prepare([entry.id])

      expect_problem(503, "ownership-moving")
      expect(body).to include("retryable" => true)
      expect_nothing_written(entry)
    end

    it "refuses every call while Timekeeping does not own entries" do
      Ownership.current.update!(owner: "monolith")

      abort_operation

      expect_problem(409, "stale-generation")
      expect(ReservationOperation.count).to eq(0)
    end
  end

  # "During this step only, the outgoing owner still applies a commit or
  # abort that carries the old generation, and only for an operation it
  # registered." The handoff closes Timekeeping's copy from `generation` to
  # the next; the existing application's settle then delivers each outcome
  # under the generation its intent was admitted under, the old one.
  describe "settle (§10.5 step 2)" do
    def close_handoff = HandoffFence.call(:close, generation:)
    def raised = { body: { "generation" => generation + 1 }, carried: generation + 1 }

    it "commits an operation it registered under the old generation, with its versions and snapshots" do
      entry = entry!(company_id: fork_and_leaf)
      prepare([entry.id])
      close_handoff

      commit

      expect_answer(:ok, "#/$defs/terminal_receipt")
      expect(body).to eq("status" => "committed")
      expect(holdings(entry)).to eq([[invoice_id, "committed", "active", true]])
      expect(ReservationOperation.sole.state).to eq("committed")
      expect(entry.reload.version).to eq(3)
      expect(OutboxSnapshot.order(:id).last).to have_attributes(entry_id: entry.id, version: 3)
      expect(OutboxSnapshot.order(:id).last.snapshot.dig("data", "locked")).to be(true)
    end

    it "aborts an operation it registered under the old generation, dropping only its provisional reservations" do
      added, kept = entry!(company_id: fork_and_leaf), entry!(company_id: fork_and_leaf)
      reservation!(kept, invoice_id:)
      prepare([added.id, kept.id])
      close_handoff

      abort_operation

      expect(body).to eq("status" => "aborted")
      expect(holdings(added)).to be_empty
      expect(holdings(kept)).to eq([[invoice_id, "committed", "active", true]])
    end

    it "answers a terminal operation's receipt again under the old generation, with no second change" do
      entry = entry!(company_id: fork_and_leaf)
      prepare([entry.id])
      commit
      close_handoff

      commit
      expect(body).to eq("status" => "committed")
      abort_operation
      expect(body).to eq("status" => "committed")

      expect(entry.reload.version).to eq(3)
    end

    it "answers the abort of a prepare that never arrived with its no-op receipt, so settle can finish (§9.3)" do
      entry = entry!(company_id: fork_and_leaf)
      close_handoff

      abort_operation

      expect_answer(:ok, "#/$defs/terminal_receipt")
      expect(body).to eq("status" => "aborted")
      expect(ReservationOperation.sole).to have_attributes(state: "aborted", company_id: fork_and_leaf, kind: nil)
      expect([entry.reload.version, OutboxSnapshot.count, Reservation.count]).to eq([1, 0, 0])
    end

    it "refuses the commit of an operation it never registered as stale-generation, with nothing written" do
      close_handoff

      commit

      expect_problem(409, "stale-generation")
      expect(ReservationOperation.count).to eq(0)
    end

    it "still refuses a prepare under the old generation as stale, and under the raised one as moving" do
      entry = entry!(company_id: fork_and_leaf)
      close_handoff

      prepare([entry.id])
      expect_problem(409, "stale-generation")
      post path("prepare"), params: JSON.generate(prepare_body([entry.id]).merge("generation" => generation + 1)),
        headers: mutating_headers(carried: generation + 1)
      expect_problem(503, "ownership-moving")

      expect_nothing_written(entry)
    end

    it "refuses a commit carrying the raised generation as moving: no operation was admitted under it" do
      entry = entry!(company_id: fork_and_leaf)
      prepare([entry.id])
      close_handoff

      commit(**raised)

      expect_problem(503, "ownership-moving")
      expect(ReservationOperation.sole.state).to eq("prepared")
    end

    it "keeps tenant isolation: another company's old-generation call naming the invoice is not-found" do
      entry = entry!(company_id: fork_and_leaf)
      prepare([entry.id])
      close_handoff

      commit(company_id: copper_kettle)
      expect_problem(404, "not-found")
      abort_operation(company_id: copper_kettle)
      expect_problem(404, "not-found")

      expect(holdings(entry)).to eq([[invoice_id, "provisional", "active", true]])
    end

    {
      "freeze" => -> { HandoffFence.call(:freeze, generation: generation + 1) },
      "an aborted handoff" => -> { HandoffFence.call(:abort, generation: generation + 1) }
    }.each do |after, step|
      it "ends with #{after}: an old-generation commit or abort is stale again, with nothing written" do
        entry = entry!(company_id: fork_and_leaf)
        prepare([entry.id])
        close_handoff
        instance_exec(&step)

        commit
        expect_problem(409, "stale-generation")
        abort_operation
        expect_problem(409, "stale-generation")

        expect(holdings(entry)).to eq([[invoice_id, "provisional", "active", true]])
        expect(ReservationOperation.sole.state).to eq("prepared")
      end
    end

    it "does not apply while Timekeeping is the incoming owner: it registered nothing to settle" do
      Ownership.current.update!(owner: "monolith")
      close_handoff

      abort_operation

      expect_problem(409, "stale-generation")
      expect(ReservationOperation.count).to eq(0)
    end
  end

  describe "contract refusals" do
    it "refuses an Idempotency-Key that is not the operation_id" do
      prepare([], headers: { key: SecureRandom.uuid })

      expect_problem(400, "invalid-request")
    end

    it "refuses a body generation that differs from X-Ownership-Generation" do
      commit(body: { "generation" => generation + 1 })

      expect_problem(400, "invalid-request")
    end

    it "refuses a body the contract does not allow" do
      post path("prepare"), params: JSON.generate(prepare_body([]).except("resolves")), headers: mutating_headers

      expect_problem(400, "invalid-request")
    end

    it "refuses a call with no token" do
      post path("commit"), params: JSON.generate("generation" => generation),
        headers: mutating_headers.except("Authorization")

      expect_problem(401, "unauthenticated")
    end

    it "refuses a call missing a mutating header" do
      post path("commit"), params: JSON.generate("generation" => generation),
        headers: mutating_headers.except("Idempotency-Key")

      expect_problem(400, "invalid-request")
    end

    it "does not route an operation id that is not a uuid, or invoice 0" do
      post "/internal/v1/invoices/#{invoice_id}/operations/not-a-uuid/commit", params: "{}", headers: mutating_headers
      expect_problem(404, "not-found")

      post path("commit", invoice: 0), params: "{}", headers: mutating_headers
      expect_problem(404, "not-found")
    end
  end
end
