# frozen_string_literal: true

require "rails_helper"

# The handoff API's checkpoint read (handoff_api.json take_checkpoint),
# provider side (§12.3): the rollback's checkpoint (§10.2 step 6, §10.5
# step 4), taken out of Timekeeping as the outgoing owner, for the handoff
# tool to carry to the prepared existing application. CheckpointTake is tested
# on its own (checkpoint_take_spec); this proves the call reaches it at the
# query's generation, answers the whole checkpoint as the contract defines it
# with every value as stored, and answers every refusal as its problem with
# nothing changed.
RSpec.describe "Handoff API: the rollback's checkpoint" do
  def body = JSON.parse(response.body)

  let(:generation) { 4 }
  let(:created_at) { Time.utc(2026, 11, 2, 9, 15, 30, 123_456) }
  let(:updated_at) { Time.utc(2026, 11, 3, 17, 45, 1, 654_321) }

  def take_checkpoint(query = { "generation" => generation.to_s }, headers: handoff_headers)
    get "/internal/v1/handoff/checkpoint", params: query, headers:
  end

  def freeze_handoff!(generation: self.generation, owner: "timekeeping", state: "frozen")
    Ownership.current.update!(generation:, owner:, state:)
  end

  def expect_problem(status, slug)
    expect(response).to have_http_status(status)
    expect(response.media_type).to eq("application/problem+json")
    expect(body).to include("type" => "https://contracts.timekeeping.internal/problems/#{slug}", "status" => status, "retryable" => false)
    expect(contract_errors("common", "#/$defs/problem", body)).to be_empty
  end

  # Everything Timekeeping holds, row by row, to show the call wrote nothing.
  def held_rows
    [Ownership, Entry, Reservation, OutboxSnapshot, EntryAudit, IdempotencyReceipt, ReservationOperation]
      .map { |model| model.order(:id).map(&:attributes) }
  end

  def operation!(invoice_id:, state:, **attributes)
    ReservationOperation.create!({ invoice_id:, operation_id: SecureRandom.uuid, state:, created_at:, updated_at: }.merge(attributes))
  end

  # Two tenants, as Timekeeping holds them after a cutover and some writes.
  # Fork & Leaf: an entry on a kept draft at version 3 with its audit rows, an
  # unlocked link, a destroyed non-draft's retained entry (§7.3) and a
  # discarded entry. Copper Kettle: an agent's entry whose metadata holds a
  # null inside an array. A committed receipt, the no-op abort of an operation
  # never prepared (§9.3), and an idempotency receipt per tenant.
  let!(:on_draft) { entry!(company_id: 1, id: 101, version: 3, duration: 0.1, note: "Kitchen prep", created_at:, updated_at:) }
  let!(:unlocked_link) { entry!(company_id: 1, id: 102, duration: 479.99999, note: nil, created_at:, updated_at:) }
  let!(:retained) { entry!(company_id: 1, id: 103, version: 2, bill_status: "billed", created_at:, updated_at:) }
  let!(:discarded) { entry!(company_id: 1, id: 104, discarded_at: Time.utc(2026, 11, 4, 8, 0, 0, 1), created_at:, updated_at:) }
  let!(:agent_entry) do
    entry!(
      company_id: 2, id: 230, version: 5, agent_id: 4, review_status: "pending_review", source: "mcp",
      source_metadata: { "mcp_server" => "miru" }, proof_metadata: { "commits" => 3, "tags" => [nil, "a"] },
      external_run_id: "run-9", external_session_id: "session-2", created_at:, updated_at:
    )
  end
  let(:noop_abort) { "8f14e45f-ceea-467f-a0e3-b4a1c3d2e5f6" }

  before do
    reservation!(on_draft, invoice_id: 501)
    reservation!(unlocked_link, invoice_id: 502, edit_lock: false)
    reservation!(retained, invoice_id: 503, disposition: "retained")
    reservation!(agent_entry, invoice_id: 601)

    on_draft.audits.create!(
      company_id: 1, action: "create", version: 1, actor: "user:7", agent_id: nil, writer: "web", request_id: "req-1",
      audited_changes: { "duration" => 0.1, "note" => nil }, created_at:
    )
    agent_entry.audits.create!(
      company_id: 2, action: "update", version: 5, actor: "agent:4", agent_id: 4, writer: "agent", request_id: "req-2",
      audited_changes: { "note" => [nil, "Proofing"] }, created_at:
    )

    operation!(invoice_id: 501, state: "committed", company_id: 1, kind: "save", invoice_state: "draft", entry_ids: [101])
    operation!(invoice_id: 701, operation_id: noop_abort, state: "aborted")

    IdempotencyReceipt.create!(
      company_id: 1, key: "web-1", request_digest: "d1", status: 201, response: { "entry" => { "id" => 101, "duration" => 0.1 } }, created_at:
    )
    IdempotencyReceipt.create!(company_id: 2, key: "web-1", request_digest: "d2", status: 200, response: { "discarded_ids" => [] }, created_at:)
  end

  describe "a settled, frozen rollback" do
    before { freeze_handoff! }

    it "answers the checkpoint the contract defines, exactly as CheckpointTake takes it" do
      taken = CheckpointTake.take(generation:)

      take_checkpoint

      expect(response).to have_http_status(200)
      expect(response.media_type).to eq("application/json")
      expect(contract_errors("handoff_api", "#/$defs/taken_checkpoint", body)).to be_empty
      expect(body).to eq(JSON.parse(taken.to_h.to_json))
    end

    it "carries every entry and reservation as stored: floats, microseconds, nulls inside metadata, held versions" do
      take_checkpoint

      expect(body["generation"]).to eq(4)
      expect(body["entries"]).to eq(JSON.parse(JSON.generate(Entry.order(:id).map(&:to_contract))))
      expect(body["entries"].map { |entry| [entry["id"], entry["version"], entry["duration"], entry["locked"]] }).to eq(
        [[101, 3, 0.1, true], [102, 1, 479.99999, false], [103, 2, 90.7, true], [104, 1, 90.7, false], [230, 5, 90.7, true]]
      )
      expect(body["entries"].first).to include("created_at" => "2026-11-02T09:15:30.123456Z", "updated_at" => "2026-11-03T17:45:01.654321Z")
      expect(body["entries"].last["proof_metadata"]).to eq("commits" => 3, "tags" => [nil, "a"])
      expect(body["reservations"]).to eq(
        [
          { "entry_id" => 101, "invoice_id" => 501, "company_id" => 1, "operation_id" => nil, "state" => "committed", "disposition" => "active", "edit_lock" => true },
          { "entry_id" => 102, "invoice_id" => 502, "company_id" => 1, "operation_id" => nil, "state" => "committed", "disposition" => "active", "edit_lock" => false },
          { "entry_id" => 103, "invoice_id" => 503, "company_id" => 1, "operation_id" => nil, "state" => "committed", "disposition" => "retained", "edit_lock" => true },
          { "entry_id" => 230, "invoice_id" => 601, "company_id" => 2, "operation_id" => nil, "state" => "committed", "disposition" => "active", "edit_lock" => true }
        ]
      )
    end

    it "carries the audit rows by id, every terminal receipt and both tenants' idempotency receipts" do
      take_checkpoint

      expect(body["entry_audits"].pluck("id")).to eq(EntryAudit.order(:id).ids)
      expect(body["entry_audits"].first).to include(
        "entry_id" => 101, "company_id" => 1, "version" => 1, "action" => "create", "actor" => "user:7", "agent_id" => nil,
        "writer" => "web", "request_id" => "req-1", "audited_changes" => { "duration" => 0.1, "note" => nil },
        "created_at" => "2026-11-02T09:15:30.123456Z"
      )
      expect(body["reservation_operations"].map { |receipt| receipt.values_at("invoice_id", "state", "company_id", "kind", "entry_ids") })
        .to eq([[501, "committed", 1, "save", [101]], [701, "aborted", nil, nil, []]])
      expect(body["reservation_operations"].last["operation_id"]).to eq(noop_abort)
      expect(body["idempotency_receipts"]).to eq(
        [
          { "company_id" => 1, "key" => "web-1", "request_digest" => "d1", "status" => 201,
            "response" => { "entry" => { "id" => 101, "duration" => 0.1 } }, "created_at" => "2026-11-02T09:15:30.123456Z" },
          { "company_id" => 2, "key" => "web-1", "request_digest" => "d2", "status" => 200,
            "response" => { "discarded_ids" => [] }, "created_at" => "2026-11-02T09:15:30.123456Z" }
        ]
      )
    end

    it "writes nothing, so the handoff tool may ask again, and leaves the record frozen" do
      before = held_rows

      take_checkpoint
      first = body
      take_checkpoint

      expect(body).to eq(first)
      expect(held_rows).to eq(before)
      expect(Ownership.current.summary).to eq("generation 4, owner timekeeping, state frozen")
    end

    it "is a GET: it needs no X-Ownership-Generation, only the generation it names" do
      take_checkpoint(headers: handoff_headers.except("X-Ownership-Generation"))

      expect(response).to have_http_status(200)
    end
  end

  describe "where the handoff must be" do
    {
      "admission still open" => { state: "open" },
      "admission closed, settle may still be running" => { state: "closed" },
      "frozen at another generation" => { generation: 5 },
      "frozen while legacy is the outgoing owner" => { owner: "legacy" },
      "frozen while the prepared application is the outgoing owner" => { owner: "monolith" }
    }.each do |name, ownership|
      it "refuses with #{name} as out-of-step, and changes nothing" do
        freeze_handoff!(**ownership)
        before = held_rows

        take_checkpoint
        expect_problem(409, "out-of-step")
        expect(body["detail"]).to match(/checkpoint expects .*nothing changed/)
        expect(held_rows).to eq(before)
      end
    end
  end

  it "takes at the generation the query names: asked for any other, it refuses as out-of-step" do
    freeze_handoff!

    [3, 5].each do |asked|
      take_checkpoint({ "generation" => asked.to_s })
      expect_problem(409, "out-of-step")
      expect(body["detail"]).to include("checkpoint expects generation #{asked} in state frozen")
    end
  end

  it "refuses a checkpoint settle did not finish as checkpoint-unsettled, listing what it found, and takes nothing" do
    freeze_handoff!
    pending = operation!(invoice_id: 801, state: "prepared", company_id: 2, kind: "save", invoice_state: "draft", entry_ids: [231])
    entry!(company_id: 2, id: 231).reservations.create!(
      invoice_id: 801, company_id: 2, state: "provisional", disposition: "active", edit_lock: true, operation_id: pending.operation_id
    )
    before = held_rows

    take_checkpoint
    expect_problem(409, "checkpoint-unsettled")
    expect(body["lists"]).to eq("provisional_reservation" => [231], "unresolved_operation" => ["801/#{pending.operation_id}"])
    expect(body["detail"]).to end_with("settle first, nothing taken")
    expect(held_rows).to eq(before)
  end

  describe "what the call must carry" do
    before { freeze_handoff! }

    it "refuses a query the contract does not allow" do
      [{}, { "generation" => "four" }, { "generation" => "-1" }, { "generation" => "04" }, { "generation" => "4", "owner" => "timekeeping" }]
        .each do |query|
          take_checkpoint(query)
          expect_problem(400, "invalid-request")
        end
    end

    it "refuses a call without the handoff tool's token, a user token among them, as unauthenticated" do
      [
        handoff_headers.except("Authorization"),
        handoff_headers(token: handoff_token(key: "another-key")),
        handoff_headers(token: handoff_token(aud: "projection", sub: "service:timekeeping-relay")),
        handoff_headers.merge("Authorization" => "Bearer #{user_token(user_token_claims(company_id: 1))}")
      ].each do |headers|
        take_checkpoint(headers:)
        expect_problem(401, "unauthenticated")
        expect(body).not_to have_key("entries")
      end
    end

    it "refuses a call without X-Request-Id" do
      take_checkpoint(headers: handoff_headers.except("X-Request-Id"))

      expect_problem(400, "invalid-request")
      expect(body["detail"]).to eq("missing headers: X-Request-Id")
    end
  end
end
