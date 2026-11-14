# frozen_string_literal: true

require "rails_helper"

# The handoff API (handoff_api.json), provider side (§12.3): the handoff
# tool's way to Timekeeping's copy of the ownership record and to the first
# cutover's checkpoint load and reconcile (docs/architecture/timekeeping-soa.md
# §10.1, §10.5). The services behind it are tested on their own
# (handoff_fence_spec, checkpoint_load_spec, checkpoint_reconcile_spec); this
# proves the calls reach them as carried, answer what the contract defines,
# and answer every refusal as its problem with nothing changed.
RSpec.describe "Handoff API" do
  def body = JSON.parse(response.body)

  def checkpointed(id:, company_id:, **fields)
    {
      "id" => id, "company_id" => company_id, "version" => 1,
      "project_id" => 10 + company_id, "user_id" => 7, "agent_id" => nil, "duration" => 90.7,
      "work_date" => "2026-11-02", "note" => "Kitchen prep", "bill_status" => "unbilled",
      "review_status" => "not_required", "locked" => false, "source" => "manual",
      "source_metadata" => {}, "proof_url" => nil, "proof_metadata" => {},
      "external_run_id" => nil, "external_session_id" => nil, "discarded_at" => nil,
      "created_at" => "2026-11-02T09:15:30.123456Z", "updated_at" => "2026-11-03T17:45:01.654321Z"
    }.merge(fields.transform_keys(&:to_s))
  end

  def reservation(entry, invoice_id:, disposition: "active", edit_lock: true, state: "committed", operation_id: nil)
    { "entry_id" => entry.fetch("id"), "invoice_id" => invoice_id, "company_id" => entry.fetch("company_id"),
      "operation_id" => operation_id, "state" => state, "disposition" => disposition, "edit_lock" => edit_lock }
  end

  # Two tenants, as the legacy checkpoint carries them: a locked entry on a
  # kept draft, an unlocked link, a retained entry and a discarded one on A;
  # an F2 release with no reservation and an agent's entry on B whose
  # metadata holds what Rails' parameter parsing would rewrite.
  let(:locked) { checkpointed(id: 101, company_id: 1, locked: true, duration: 0.1) }
  let(:unlocked_link) { checkpointed(id: 102, company_id: 1, duration: 479.99999, note: nil) }
  let(:retained) { checkpointed(id: 103, company_id: 1, locked: true, bill_status: "billed") }
  let(:discarded) { checkpointed(id: 104, company_id: 1, discarded_at: "2026-11-04T08:00:00.000001Z") }
  let(:released) { checkpointed(id: 205, company_id: 2, bill_status: "non_billable") }
  let(:agent_entry) do
    checkpointed(
      id: 230, company_id: 2, agent_id: 4, review_status: "pending_review", source: "mcp",
      source_metadata: { "mcp_server" => "miru", "skipped" => [nil], "tags" => [] },
      proof_metadata: { "commits" => 3, "verified" => false, "steps" => [nil, "build"] },
      external_run_id: "run-9", external_session_id: "session-2"
    )
  end
  let(:entries) { [locked, unlocked_link, retained, discarded, released, agent_entry] }
  let(:reservations) do
    [
      reservation(locked, invoice_id: 501),
      reservation(unlocked_link, invoice_id: 502, edit_lock: false),
      reservation(retained, invoice_id: 503, disposition: "retained")
    ]
  end

  def checkpoint(generation: 1, entries: self.entries, reservations: self.reservations)
    { "generation" => generation, "entries" => entries, "reservations" => reservations }
  end

  def read_handoff(headers: handoff_headers)
    get "/internal/v1/handoff", headers:
  end

  def run_step(name, generation, carried: generation, headers: handoff_headers(generation: carried))
    post "/internal/v1/handoff/steps/#{name}", params: JSON.generate({ "generation" => generation }), headers:
  end

  def load_checkpoint(payload = checkpoint, carried: payload["generation"])
    post "/internal/v1/handoff/checkpoint", params: JSON.generate(payload), headers: handoff_headers(generation: carried)
  end

  def reconcile_checkpoint(payload = checkpoint, carried: payload["generation"])
    post "/internal/v1/handoff/checkpoint/reconcile", params: JSON.generate(payload), headers: handoff_headers(generation: carried)
  end

  def expect_answer(status, pointer)
    expect(response).to have_http_status(status)
    expect(response.media_type).to eq("application/json")
    expect(contract_errors("handoff_api", pointer, body)).to be_empty
  end

  def expect_problem(status, slug, retryable: false)
    expect(response).to have_http_status(status)
    expect(response.media_type).to eq("application/problem+json")
    expect(body).to include("type" => "https://contracts.timekeeping.internal/problems/#{slug}", "status" => status, "retryable" => retryable)
    expect(contract_errors("common", "#/$defs/problem", body)).to be_empty
  end

  def ownership = Ownership.current.summary

  # Everything Timekeeping holds, row by row, to show a refusal wrote nothing.
  def held_rows
    [Ownership, Entry, Reservation, OutboxSnapshot, EntryAudit, IdempotencyReceipt, ReservationOperation]
      .map { |model| model.order(:id).map(&:attributes) }
  end

  def freeze_for_cutover!
    Ownership.current.update!(generation: 1, owner: "legacy", state: "frozen")
  end

  it "is a valid schema listing the four operations the handoff tool calls, and every step of the state machine" do
    expect(JSONSchemer.valid_schema?(contract_document(:handoff_api))).to be(true)
    expect(contract_document(:handoff_api).dig("$defs", "step", "enum")).to eq(TimekeepingReservations::Handoff::STEPS.keys.map(&:to_s))

    operations = contract_document(:handoff_api).fetch("x-operations").values.map { |operation| "#{operation['method']} #{operation['path']}" }

    expect(operations).to contain_exactly(
      "GET /internal/v1/handoff",
      "POST /internal/v1/handoff/steps/{step}",
      "POST /internal/v1/handoff/checkpoint",
      "POST /internal/v1/handoff/checkpoint/reconcile"
    )
  end

  describe "the first cutover, as the handoff tool drives Timekeeping's side of it" do
    it "closes, freezes, loads, reconciles and flips the copy, answering each step as it left the record" do
      read_handoff
      expect_answer(200, "#/$defs/handoff_status")
      expect(body).to eq(
        "ownership" => { "generation" => 0, "owner" => "legacy", "state" => "open" },
        "outbox" => { "latest_position" => nil, "undelivered" => 0 }
      )

      run_step("close", 0)
      expect_answer(200, "#/$defs/handoff_status")
      expect(body["ownership"]).to eq("generation" => 1, "owner" => "legacy", "state" => "closed")

      run_step("freeze", 1)
      expect(body["ownership"]).to eq("generation" => 1, "owner" => "legacy", "state" => "frozen")

      load_checkpoint
      expect_answer(200, "#/$defs/checkpoint_receipt")
      expect(body).to eq("entries" => 6, "reservations" => 3)

      read_handoff
      expect(body["outbox"]).to eq("latest_position" => OutboxSnapshot.maximum(:id), "undelivered" => 6)

      reconcile_checkpoint
      expect_answer(200, "#/$defs/checkpoint_receipt")
      expect(body).to eq("entries" => 6, "reservations" => 3)

      run_step("flip", 1)
      expect_answer(200, "#/$defs/handoff_status")
      expect(body["ownership"]).to eq("generation" => 1, "owner" => "timekeeping", "state" => "open")
      expect(Ownership.admit!(1)).to be_owner_timekeeping
    end

    it "aborts a handoff, keeping the raised generation" do
      run_step("close", 0)
      run_step("abort", 1)

      expect_answer(200, "#/$defs/handoff_status")
      expect(body["ownership"]).to eq("generation" => 1, "owner" => "legacy", "state" => "open")
    end

    it "loads the checkpoint exactly as carried: floats, microseconds, nulls inside metadata, the handoff's request id" do
      freeze_for_cutover!
      load_checkpoint

      expect(Entry.order(:id).map(&:to_contract)).to eq(entries)
      expect(Entry.find(230).source_metadata).to eq("mcp_server" => "miru", "skipped" => [nil], "tags" => [])
      expect(Entry.order(:id).pluck(:duration)).to eq([0.1, 479.99999, 90.7, 90.7, 90.7, 90.7])
      expect(Reservation.order(:entry_id).map(&:to_value).map { |value| Reservation.row_for(value).stringify_keys })
        .to eq(reservations)
      expect(OutboxSnapshot.distinct.pluck(:request_id)).to eq(["handoff-1"])
    end

    it "reports the relay's progress: nothing undelivered once it has delivered through the latest position" do
      freeze_for_cutover!
      load_checkpoint
      OutboxSnapshot.update_all(delivered_at: Time.current)

      read_handoff
      expect(body["outbox"]).to eq("latest_position" => OutboxSnapshot.maximum(:id), "undelivered" => 0)
    end
  end

  describe "a step out of step (a replay, a second tool, or a resumed handoff that misread the copy)" do
    it "refuses as out-of-step and changes nothing" do
      run_step("close", 0)
      before = held_rows

      run_step("close", 0)
      expect_problem(409, "out-of-step")
      expect(body["detail"]).to match(/close expects generation 0 in state open, found generation 1, owner legacy, state closed; nothing changed/)

      run_step("flip", 1)
      expect_problem(409, "out-of-step")
      expect(held_rows).to eq(before)
    end

    it "does not know a step the state machine does not have" do
      run_step("settle", 0)

      expect_problem(404, "not-found")
      expect(Ownership.current).to be_new_record
    end

    it "answers a step whose lock waited out the calls already admitted as retryable drain-timeout" do
      allow(HandoffFence).to receive(:call).and_raise(ActiveRecord::LockWaitTimeout)

      run_step("close", 0)
      expect_problem(503, "drain-timeout", retryable: true)
      expect(Ownership.current).to be_new_record
    end
  end

  describe "the checkpoint load's refusals" do
    before { freeze_for_cutover! }

    it "refuses a load outside the frozen first cutover as out-of-step" do
      Ownership.current.update!(state: "closed")

      load_checkpoint
      expect_problem(409, "out-of-step")
      expect(Entry.count).to eq(0)
    end

    it "answers a second load as already-loaded, so a resumed handoff goes on to reconcile" do
      load_checkpoint
      before = held_rows

      load_checkpoint
      expect_problem(409, "already-loaded")
      expect(held_rows).to eq(before)
    end

    it "refuses a checkpoint that does not hold together, listing the entry ids per check, and loads nothing" do
      broken = checkpoint(
        entries: [locked.merge("locked" => false), unlocked_link.merge("bill_status" => "paid"), retained],
        reservations: [
          reservation(locked, invoice_id: 501),
          reservation(retained, invoice_id: 503, disposition: "retained"),
          reservation(released, invoice_id: 504),
          reservation(unlocked_link, invoice_id: 502, state: "provisional", operation_id: SecureRandom.uuid, edit_lock: false)
        ]
      )

      load_checkpoint(broken)
      expect_problem(422, "checkpoint-refused")
      expect(body["lists"]).to eq(
        "not_a_contract_entry" => [102], "reservation_without_its_entry" => [205],
        "provisional_reservation" => [102], "locked_not_derived" => [101]
      )
      expect(Entry.count).to eq(0)
    end
  end

  describe "the checkpoint reconcile's refusals" do
    before do
      freeze_for_cutover!
      load_checkpoint
    end

    it "answers every difference as checkpoint-differs, listing what each check found, and changes nothing" do
      before = held_rows
      carried = checkpoint(
        entries: [locked, unlocked_link.merge("duration" => 479.99998), retained, discarded, released],
        reservations: [reservation(locked, invoice_id: 599), reservation(unlocked_link, invoice_id: 502, edit_lock: false),
          reservation(retained, invoice_id: 503, disposition: "retained")]
      )

      reconcile_checkpoint(carried)
      expect_problem(409, "checkpoint-differs")
      expect(body["lists"]).to eq("entry_unexpected" => [230], "entry_differs" => [102], "reservations_differ" => [101])
      expect(held_rows).to eq(before)
    end

    it "refuses a reconcile outside the frozen first cutover as out-of-step" do
      run_step("flip", 1)

      reconcile_checkpoint
      expect_problem(409, "out-of-step")
    end
  end

  describe "what every call must carry" do
    it "refuses a call without the handoff tool's token, a user token among them, as unauthenticated" do
      [
        handoff_headers.except("Authorization"),
        handoff_headers(token: handoff_token(key: "another-key")),
        handoff_headers(token: handoff_token(aud: "projection", sub: "service:timekeeping-relay")),
        handoff_headers.merge("Authorization" => "Bearer #{user_token(user_token_claims(company_id: 1))}")
      ].each do |headers|
        read_handoff(headers:)
        expect_problem(401, "unauthenticated")

        run_step("close", 0, headers: headers.merge("X-Ownership-Generation" => "0"))
        expect_problem(401, "unauthenticated")
      end
      expect(Ownership.current).to be_new_record
    end

    it "refuses a call without X-Request-Id, and a step or load without X-Ownership-Generation" do
      read_handoff(headers: handoff_headers.except("X-Request-Id"))
      expect_problem(400, "invalid-request")

      run_step("close", 0, headers: handoff_headers)
      expect_problem(400, "invalid-request")
      expect(body["detail"]).to eq("missing headers: X-Ownership-Generation")
      expect(Ownership.current).to be_new_record
    end

    it "refuses a generation the body and X-Ownership-Generation disagree on" do
      run_step("close", 0, carried: 1)
      expect_problem(400, "invalid-request")
      expect(body["detail"]).to eq("body generation differs from X-Ownership-Generation")

      freeze_for_cutover!
      load_checkpoint(checkpoint, carried: 2)
      expect_problem(400, "invalid-request")
      expect(Entry.count).to eq(0)
    end

    it "refuses a body the contract does not allow, and one that is not JSON" do
      post "/internal/v1/handoff/steps/close", params: JSON.generate({ "generation" => 0, "owner" => "timekeeping" }),
        headers: handoff_headers(generation: 0)
      expect_problem(400, "invalid-request")

      freeze_for_cutover!
      load_checkpoint(checkpoint(reservations: [reservation(locked, invoice_id: 501).merge("disposition" => "released")]))
      expect_problem(400, "invalid-request")

      load_checkpoint(checkpoint(entries: [locked.except("id")]))
      expect_problem(400, "invalid-request")

      post "/internal/v1/handoff/checkpoint", params: "{not json", headers: handoff_headers(generation: 1)
      expect_problem(400, "invalid-request")
      expect(Entry.count).to eq(0)
    end
  end
end
