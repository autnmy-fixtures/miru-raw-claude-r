# frozen_string_literal: true

require "rails_helper"

# The handoff API's re-cutover reconcile (handoff_api.json
# reconcile_recutover_checkpoint), provider side (§12.3): step 6 of the
# re-cutover (§10.2 step 6, §10.5 step 6, §10.4), the checkpoint taken out of
# the prepared application carried to Timekeeping a second time, once the load
# has run, and compared with what Timekeeping then holds. RecutoverReconcile is
# tested on its own (recutover_reconcile_spec); this proves the call reaches it
# with the checkpoint exactly as carried, answers what the contract defines,
# and answers every difference and refusal as its problem, writing nothing.
RSpec.describe "Handoff API: the re-cutover's checkpoint reconcile" do
  include_context "a re-cutover checkpoint"

  def body = JSON.parse(response.body)

  # The checkpoint as the wire carries it: the contract's JSON, values in the
  # forms the take answers them.
  let(:payload) { JSON.parse(checkpoint.to_h.to_json) }

  def post_checkpoint(path, carried_payload, carried, headers)
    post "/internal/v1/handoff/recutover/#{path}", params: JSON.generate(carried_payload), headers: headers || handoff_headers(generation: carried)
  end

  def load_recutover(carried_payload = payload) = post_checkpoint("checkpoint", carried_payload, carried_payload["generation"], nil)

  def reconcile_recutover(carried_payload = payload, carried: carried_payload["generation"], headers: nil)
    post_checkpoint("checkpoint/reconcile", carried_payload, carried, headers)
  end

  def loaded!
    load_recutover
    expect(response).to have_http_status(200)
  end

  def expect_problem(status, slug)
    expect(response).to have_http_status(status)
    expect(response.media_type).to eq("application/problem+json")
    expect(body).to include("type" => "https://contracts.timekeeping.internal/problems/#{slug}", "status" => status, "retryable" => false)
    expect(contract_errors("common", "#/$defs/problem", body)).to be_empty
  end

  def entries_with(id, **changes)
    payload.fetch("entries").map { |entry| entry["id"] == id ? entry.merge(changes.transform_keys(&:to_s)) : entry }
  end

  describe "after the load, over the same API" do
    it "agrees, and answers how many rows of each part it reconciled, as the contract defines" do
      loaded!

      reconcile_recutover

      expect(response).to have_http_status(200)
      expect(response.media_type).to eq("application/json")
      expect(contract_errors("handoff_api", "#/$defs/recutover_receipt", body)).to be_empty
      expect(body).to eq(
        "entries" => 6, "reservations" => 4, "entry_audits" => 6, "reservation_operations" => 6, "idempotency_receipts" => 3
      )
    end

    it "reads the body exactly as sent: a null inside an entry's metadata reconciles as carried (§8 item 1)" do
      loaded!
      expect(payload.fetch("entries").find { |entry| entry["id"] == 230 }.fetch("proof_metadata")).to eq("tags" => [nil, "a"])

      reconcile_recutover

      expect(response).to have_http_status(200)
    end

    it "writes nothing, and leaves the record frozen for the flip, however often the tool asks" do
      loaded!
      before = held_rows

      2.times do
        reconcile_recutover
        expect(response).to have_http_status(200)
      end

      expect(held_rows).to eq(before)
      expect(Ownership.current.summary).to eq("generation 6, owner monolith, state frozen")
    end
  end

  describe "a difference, answered as checkpoint-differs listing what each check found, with nothing changed" do
    # A resumed handoff that skipped the load, or a load whose response was
    # lost before it ran: Timekeeping still holds what it held at the rollback.
    it "finds every part the load would have changed when it never ran" do
      payload
      before = held_rows

      reconcile_recutover
      expect_problem(409, "checkpoint-differs")
      expect(body["lists"]).to eq(
        "entry_missing" => [240],
        "entry_differs" => [101, 102],
        "entry_audit_missing" => [14, 15, 16],
        "reservation_operation_missing" => ["501/#{released_draft_operation}", "602/#{new_draft_operation}", "603/#{aborted_operation}"],
        "idempotency_receipt_missing" => ["2/web-2"],
        "reservations_differ" => [101, 240]
      )
      expect(body["detail"]).to end_with("abort the handoff")
      expect(held_rows).to eq(before)
    end

    it "finds a write that slipped past the fence after the load" do
      loaded!
      Entry.where(id: 230).update_all(note: "rewritten")
      before = held_rows

      reconcile_recutover
      expect_problem(409, "checkpoint-differs")
      expect(body["lists"]).to eq("entry_differs" => [230])
      expect(body["detail"]).to eq("Timekeeping checkpoint reconcile: entry_differs 230; abort the handoff")
      expect(held_rows).to eq(before)
    end

    it "compares exactly what the wire carries: a duration one digit off, a timestamp in another form, a reservation carried twice" do
      loaded!
      audits = payload.fetch("entry_audits").map { |audit| audit["id"] == 14 ? audit.merge("created_at" => "2026-11-12T10:20:30.000007+00:00") : audit }

      reconcile_recutover(payload.merge(
        "entries" => entries_with(102, duration: 479.99998),
        "entry_audits" => audits,
        "reservations" => payload.fetch("reservations") + [payload.fetch("reservations").last.merge("invoice_id" => 699)]
      ))
      expect_problem(409, "checkpoint-differs")
      expect(body["lists"]).to eq("entry_differs" => [102], "entry_audit_differs" => [14], "reservations_differ" => [240])
    end

    it "finds rows carried that Timekeeping does not hold, and rows held that are not carried" do
      loaded!

      reconcile_recutover(payload.merge(
        "entries" => payload.fetch("entries") + [payload.fetch("entries").last.merge("id" => 250)],
        "idempotency_receipts" => payload.fetch("idempotency_receipts").reject { |row| row["key"] == "web-2" }
      ))
      expect_problem(409, "checkpoint-differs")
      expect(body["lists"]).to eq("entry_missing" => [250], "idempotency_receipt_unexpected" => ["2/web-2"])
    end
  end

  describe "where the handoff must be" do
    {
      "admission still open" => { state: "open" },
      "admission closed, settle may still be running" => { state: "closed" },
      "frozen at another generation" => { generation: 7 },
      "frozen while legacy is the outgoing owner (the first cutover)" => { owner: "legacy" },
      "frozen while Timekeeping is the outgoing owner (a rollback)" => { owner: "timekeeping" }
    }.each do |name, ownership|
      it "refuses with #{name} as out-of-step, and changes nothing" do
        loaded!
        ownership!(**ownership)
        before = held_rows

        reconcile_recutover
        expect_problem(409, "out-of-step")
        expect(body["detail"]).to match(/reconcile expects .*nothing changed/)
        expect(held_rows).to eq(before)
      end
    end

    it "refuses after the flip, so a late reconcile cannot pass a handoff already done" do
      loaded!
      ownership!(owner: "timekeeping", state: "open")

      reconcile_recutover
      expect_problem(409, "out-of-step")
    end
  end

  describe "what the call must carry" do
    before { loaded! }

    it "refuses a body the contract does not allow, and one that is not JSON, changing nothing" do
      before = held_rows

      [
        payload.except("idempotency_receipts"),
        payload.merge("outbox" => []),
        payload.merge("entries" => payload.fetch("entries").map { |entry| entry["id"] == 240 ? entry.except("version") : entry }),
        payload.merge("reservations" => payload.fetch("reservations").map { |row| row.merge("disposition" => "released") }),
        payload.merge("entry_audits" => payload.fetch("entry_audits").map { |audit| audit.except("id") }),
        payload.merge("reservation_operations" => payload.fetch("reservation_operations").map { |row| row.merge("operation_id" => "op-1") }),
        payload.merge("idempotency_receipts" => payload.fetch("idempotency_receipts").map { |row| row.except("key") })
      ].each do |invalid|
        reconcile_recutover(invalid, carried: generation)
        expect_problem(400, "invalid-request")
      end

      post "/internal/v1/handoff/recutover/checkpoint/reconcile", params: "{not json", headers: handoff_headers(generation:)
      expect_problem(400, "invalid-request")
      expect(held_rows).to eq(before)
    end

    it "refuses a generation the body and X-Ownership-Generation disagree on, and a call without either header it needs" do
      reconcile_recutover(payload, carried: 7)
      expect_problem(400, "invalid-request")
      expect(body["detail"]).to eq("body generation differs from X-Ownership-Generation")

      reconcile_recutover(headers: handoff_headers)
      expect_problem(400, "invalid-request")
      expect(body["detail"]).to eq("missing headers: X-Ownership-Generation")

      reconcile_recutover(headers: handoff_headers(generation:).except("X-Request-Id"))
      expect_problem(400, "invalid-request")
      expect(body["detail"]).to eq("missing headers: X-Request-Id")
    end

    it "refuses a call without the handoff tool's token, a user token among them, as unauthenticated" do
      [
        handoff_headers(generation:).except("Authorization"),
        handoff_headers(generation:, token: handoff_token(key: "another-key")),
        handoff_headers(generation:, token: handoff_token(aud: "projection", sub: "service:timekeeping-relay")),
        handoff_headers(generation:).merge("Authorization" => "Bearer #{user_token(user_token_claims(company_id: 1))}")
      ].each do |headers|
        reconcile_recutover(headers:)
        expect_problem(401, "unauthenticated")
      end
    end
  end
end
