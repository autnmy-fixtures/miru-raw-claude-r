# frozen_string_literal: true

require "rails_helper"

# W6's agent detach (§3.1, §5.2), provider side (§12.3): one mutating call,
# admitted under the carried generation (§10.1), that nulls agent_id on every
# entry of the token's company that names the agent, discarded ones included,
# as today's `dependent: :nullify` (update_all) does (K8). Each detached entry
# gets its next version, an audit row and an outbox snapshot, in one
# transaction with the call's idempotency receipt (§3.4), and keeps its
# updated_at, as update_all keeps it. No rule runs, and the company is the
# only check (§6.2).
RSpec.describe "Entry API agent detach" do
  let(:fork_and_leaf) { 1 }
  let(:copper_kettle) { 2 }
  let(:generation) { 3 }
  let(:agent_id) { 5 }

  before { Ownership.create!(generation:, owner: "timekeeping", state: "open") }

  def body = JSON.parse(response.body)

  # The destroying user's token as the agent_destroy writer (§6.1).
  def mutating_headers(company_id: fork_and_leaf, key: "key-1", carried: generation, **claims)
    entry_api_headers(company_id:, writer: "agent_destroy", **claims)
      .merge("Idempotency-Key" => key, "X-Ownership-Generation" => carried.to_s, "Content-Type" => "application/json")
  end

  # The body is positional and always braced, so it never folds into
  # **headers.
  def detach(id = agent_id, body = {}, **headers)
    post "/internal/v1/agents/#{id}/detach", params: JSON.generate(body), headers: mutating_headers(**headers)
  end

  def expect_problem(status, slug)
    expect(response).to have_http_status(status)
    expect(response.media_type).to eq("application/problem+json")
    expect(body).to include("type" => "https://contracts.timekeeping.internal/problems/#{slug}", "status" => status)
    expect(contract_errors("common", "#/$defs/problem", body)).to be_empty
  end

  def named!(company_id: fork_and_leaf, **attributes) = entry!(company_id:, agent_id:, review_status: "pending_review", **attributes)

  def expect_unchanged(*entries)
    entries.each { |entry| expect(entry.reload).to have_attributes(version: 1, agent_id:) }
    expect([EntryAudit.count, OutboxSnapshot.count, IdempotencyReceipt.count]).to eq([0, 0, 0])
  end

  it "nulls agent_id on each entry that names the agent and answers their ids as the contract states it" do
    second, first = named!, named!
    other_agent = named!(agent_id: agent_id + 1)
    unnamed = entry!(company_id: fork_and_leaf)

    detach

    expect(response).to have_http_status(:ok)
    expect(contract_errors("entry_api", "#/$defs/detach_agent_response", body)).to be_empty
    expect(body).to eq("detached_ids" => [second.id, first.id].sort)
    expect([first.reload, second.reload]).to all(have_attributes(agent_id: nil, version: 2, discarded_at: nil))
    expect(other_agent.reload).to have_attributes(agent_id: agent_id + 1, version: 1)
    expect(unnamed.reload.version).to eq(1)
  end

  it "writes one update audit row and one outbox snapshot per detached entry, as the agent_destroy writer (§3.4)" do
    entry = named!

    detach

    entry.reload
    expect(entry.audits.sole).to have_attributes(
      company_id: fork_and_leaf, action: "update", version: 2, actor: "user:7", agent_id: nil,
      writer: "agent_destroy", request_id: "req-#{fork_and_leaf}", audited_changes: { "agent_id" => [agent_id, nil] }
    )
    snapshot = entry.outbox_snapshots.sole.snapshot
    expect(snapshot).to eq(OutboxSnapshot.of(entry))
    expect(snapshot.dig("data", "agent_id")).to be_nil
    expect(contract_errors("entry_snapshot", "#/$defs/entry_snapshot", snapshot)).to be_empty
  end

  it "records the system actor when no user destroys the agent, as from a job or the console (§6.1)" do
    entry = named!

    detach(sub: "system", role: nil, actor: { "type" => "system", "agent_id" => nil })

    expect(entry.audits.sole).to have_attributes(actor: "system", writer: "agent_destroy")
  end

  it "keeps updated_at, review_status and the rest of the entry, as update_all changes only agent_id (K8)" do
    stamped = 2.days.ago.change(usec: 0)
    entry = named!(updated_at: stamped)
    before = entry.to_contract

    detach

    expect(entry.reload.to_contract).to eq(before.merge("agent_id" => nil, "version" => 2))
    expect(entry.updated_at).to eq(stamped)
  end

  it "detaches a discarded entry too, as update_all reaches it, and leaves it discarded" do
    discarded = named!(discarded_at: 1.day.ago)

    detach

    expect(body).to eq("detached_ids" => [discarded.id])
    expect(discarded.reload).to have_attributes(agent_id: nil, version: 2, discarded_at: be_present)
  end

  it "runs no rule and reads no role: a billed, locked or out-of-window entry is detached for an employee" do
    billed = named!(bill_status: "billed", work_date: Date.current - 30)
    locked = named!.tap { |entry| reservation!(entry, invoice_id: 3) }

    detach(role: "employee", timesheet_edit_days: 0)

    expect(body).to eq("detached_ids" => [billed.id, locked.id])
    expect([billed.reload, locked.reload]).to all(have_attributes(agent_id: nil))
    expect(locked.reservations.sole).to have_attributes(invoice_id: 3, disposition: "active", edit_lock: true)
  end

  it "answers no ids and writes only its receipt for an agent no entry names" do
    entry!(company_id: fork_and_leaf)

    detach

    expect(response).to have_http_status(:ok)
    expect(body).to eq("detached_ids" => [])
    expect([EntryAudit.count, OutboxSnapshot.count, IdempotencyReceipt.count]).to eq([0, 0, 1])
  end

  describe "tenant isolation (§6.2, §6.3)" do
    it "touches nothing of another company, even an entry naming the same agent id" do
      mine = named!
      theirs = named!(company_id: copper_kettle)

      detach

      expect(body).to eq("detached_ids" => [mine.id])
      expect(theirs.reload).to have_attributes(agent_id:, version: 1)
      expect(theirs.audits).to be_empty
    end

    it "detaches in the other company only under that company's token" do
      mine = named!
      theirs = named!(company_id: copper_kettle)

      detach(company_id: copper_kettle)

      expect(body).to eq("detached_ids" => [theirs.id])
      expect(mine.reload.agent_id).to eq(agent_id)
    end
  end

  describe "admission (§10.1)" do
    it "refuses a stale generation and a moving owner, changing nothing" do
      entry = named!

      detach(carried: generation - 1)
      expect_problem(409, "stale-generation")

      Ownership.current.update!(state: "closed")
      detach
      expect_problem(503, "ownership-moving")
      expect(body.fetch("retryable")).to be(true)

      expect_unchanged(entry)
    end
  end

  describe "idempotency (§9.4)" do
    it "replays the stored answer for the same key, instead of answering nothing detached" do
      entry = named!
      detach
      first = body

      detach

      expect(body).to eq(first)
      expect(entry.reload.version).to eq(2)
      expect([EntryAudit.count, OutboxSnapshot.count, IdempotencyReceipt.count]).to eq([1, 1, 1])
    end

    it "answers nothing detached for a repeat under a new key, so a repeat is harmless" do
      entry = named!
      detach

      detach(key: "key-2")

      expect(body).to eq("detached_ids" => [])
      expect(entry.reload.version).to eq(2)
    end

    it "refuses the same key for another agent's path" do
      named!
      detach

      detach(agent_id + 1)

      expect_problem(409, "idempotency-conflict")
    end
  end

  describe "the contract (§5.2)" do
    it "refuses a non-empty body, changing nothing" do
      entry = named!

      detach(agent_id, { "agent_id" => agent_id })

      expect_problem(400, "invalid-request")
      expect_unchanged(entry)
    end

    it "refuses a call without its mutating headers or token" do
      entry = named!

      post "/internal/v1/agents/#{agent_id}/detach", params: "{}", headers: mutating_headers.except("Idempotency-Key")
      expect_problem(400, "invalid-request")

      post "/internal/v1/agents/#{agent_id}/detach", params: "{}", headers: mutating_headers.except("Authorization")
      expect_problem(401, "unauthenticated")

      expect_unchanged(entry)
    end

    it "has no agent 0" do
      detach(0)

      expect_problem(404, "not-found")
    end
  end
end
