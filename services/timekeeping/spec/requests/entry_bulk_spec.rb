# frozen_string_literal: true

require "rails_helper"

# W2's bulk move and bulk discard (§5.2), provider side (§12.3): one mutating
# call each, admitted under the carried generation (§10.1), that holds the
# named kept entries of the token's company FOR UPDATE, checks A9's lock on
# every one of them (§6.2), and writes each changed entry's next version, its
# audit row and its outbox snapshot, and the call's idempotency receipt, in
# one transaction (§3.4), or nothing. A move skips an entry the update rules
# reject and still answers 200 (A9, K12); a discard runs no rule.
RSpec.describe "Entry API bulk move and bulk discard" do
  let(:fork_and_leaf) { 1 }
  let(:copper_kettle) { 2 }
  let(:generation) { 3 }

  let(:target_project) { { "id" => 13, "company_id" => fork_and_leaf, "kept" => true, "billable" => true } }
  let(:non_billable_project) { { "id" => 12, "company_id" => fork_and_leaf, "kept" => true, "billable" => false } }

  before { Ownership.create!(generation:, owner: "timekeeping", state: "open") }

  def body = JSON.parse(response.body)

  # An entry of user 7 in Fork & Leaf's billable project 11, worked today,
  # so it is inside every edit window.
  def owned!(**attributes) = entry!(company_id: fork_and_leaf, work_date: Date.current, note: "Before", **attributes)

  def mutating_headers(company_id: fork_and_leaf, key: "key-1", carried: generation, project: target_project, **claims)
    entry_api_headers(company_id:, project:, writer: "bulk", **claims).merge(
      "Idempotency-Key" => key, "X-Ownership-Generation" => carried.to_s, "Content-Type" => "application/json"
    )
  end

  # The body is positional and always braced: Ruby folds a trailing
  # string-keyed hash into **headers otherwise.
  def bulk_move(ids, body = { "project_id" => 13 }, **headers)
    post "/internal/v1/entries/bulk_move", params: JSON.generate({ "ids" => ids }.merge(body)), headers: mutating_headers(**headers)
  end

  def bulk_discard(ids, body = {}, **headers)
    post "/internal/v1/entries/bulk_discard", params: JSON.generate({ "ids" => ids }.merge(body)), headers: mutating_headers(project: nil, **headers)
  end

  def expect_problem(status, slug)
    expect(response).to have_http_status(status)
    expect(response.media_type).to eq("application/problem+json")
    expect(body).to include("type" => "https://contracts.timekeeping.internal/problems/#{slug}", "status" => status)
    expect(contract_errors("common", "#/$defs/problem", body)).to be_empty
  end

  # Nothing changed: the entries as they were, and no audit, outbox or
  # receipt row.
  def expect_unchanged(*entries)
    entries.each { |entry| expect(entry.reload).to have_attributes(version: 1, project_id: 11, discarded_at: nil) }
    expect([EntryAudit.count, OutboxSnapshot.count, IdempotencyReceipt.count]).to eq([0, 0, 0])
  end

  describe "POST /internal/v1/entries/bulk_move" do
    it "moves each named entry as its next version and answers them as the contract states it" do
      first, second = owned!, owned!(user_id: 9)

      bulk_move([second.id, first.id])

      expect(response).to have_http_status(:ok)
      expect(contract_errors("entry_api", "#/$defs/bulk_move_response", body)).to be_empty
      expect(body).to include("moved_ids" => [first.id, second.id], "skipped_ids" => [])
      expect(body.fetch("entries")).to eq([first.reload.to_contract, second.reload.to_contract])
      expect([first, second]).to all(have_attributes(project_id: 13, version: 2))
    end

    it "writes one update audit row and one outbox snapshot per moved entry, as the bulk writer (§3.4)" do
      entry = owned!

      bulk_move([entry.id])

      entry.reload
      expect(entry.audits.sole).to have_attributes(
        company_id: fork_and_leaf, action: "update", version: 2, actor: "user:7", writer: "bulk",
        request_id: "req-#{fork_and_leaf}", audited_changes: { "project_id" => [11, 13] }
      )
      outbox = entry.outbox_snapshots.sole
      expect(outbox).to have_attributes(version: 2, request_id: "req-#{fork_and_leaf}")
      expect(contract_errors("entry_snapshot", "#/$defs/entry_snapshot", outbox.snapshot)).to be_empty
      expect(outbox.snapshot).to eq(OutboxSnapshot.of(entry))
    end

    it "answers an entry already in the target project as moved, writing nothing for it, as today's update saves nothing" do
      entry = owned!(project_id: 13)

      bulk_move([entry.id])

      expect(body).to include("moved_ids" => [entry.id], "skipped_ids" => [])
      expect(entry.reload.version).to eq(1)
      expect([EntryAudit.count, OutboxSnapshot.count]).to eq([0, 0])
    end

    describe "A9's silent skip (K12)" do
      it "skips an employee's locked entry, moves the rest and still answers 200" do
        locked = owned!.tap { |row| reservation!(row, invoice_id: 3) }
        free = owned!

        bulk_move([locked.id, free.id], role: "employee")

        expect(response).to have_http_status(:ok)
        expect(body).to include("moved_ids" => [free.id], "skipped_ids" => [locked.id])
        expect(body.fetch("entries")).to eq([locked.reload.to_contract, free.reload.to_contract])
        expect(body.fetch("entries").first).to include("project_id" => 11, "locked" => true, "version" => 1)
        expect(locked.audits).to be_empty
        expect(locked.outbox_snapshots).to be_empty
        expect(free).to have_attributes(project_id: 13, version: 2)
      end

      it "moves a locked entry for an owner or admin, as the lock stops employees only (L1)" do
        entry = owned!.tap { |row| reservation!(row, invoice_id: 3) }

        bulk_move([entry.id], role: "admin")

        expect(body).to include("moved_ids" => [entry.id], "skipped_ids" => [])
        expect(entry.reload.project_id).to eq(13)
      end

      it "skips an unbilled entry moved to a non-billable project, and moves a non-billable one" do
        unbilled = owned!
        non_billable = owned!(bill_status: "non_billable")

        bulk_move([unbilled.id, non_billable.id], { "project_id" => 12 }, project: non_billable_project)

        expect(body).to include("moved_ids" => [non_billable.id], "skipped_ids" => [unbilled.id])
        expect(unbilled.reload).to have_attributes(project_id: 11, version: 1)
        expect(non_billable.reload).to have_attributes(project_id: 12, version: 2)
      end
    end

    describe "A9's lock, on the rows the write holds" do
      it "refuses the whole request as entry-locked when one entry is billed, for every role, moving none" do
        billed = owned!(bill_status: "billed")
        free = owned!

        bulk_move([free.id, billed.id], role: "owner")

        expect_problem(403, "entry-locked")
        expect(body.fetch("detail")).to include("entry #{billed.id}", "(A3)")
        expect(billed.reload).to have_attributes(project_id: 11, version: 1)
        expect_unchanged(free)
      end

      it "refuses an employee an entry older than the edit window, and lets an owner or admin move it" do
        stale = owned!(work_date: Date.current - 8)

        bulk_move([stale.id], role: "employee")
        expect_problem(403, "entry-locked")
        expect(body.fetch("detail")).to include("(A4)")
        expect_unchanged(stale)

        bulk_move([stale.id], key: "key-2", role: "admin")
        expect(body).to include("moved_ids" => [stale.id])
      end

      it "does not check A5: the caller's policy scope chose the entries (A6)" do
        someone_elses = owned!(user_id: 9)

        bulk_move([someone_elses.id], role: "employee")

        expect(body).to include("moved_ids" => [someone_elses.id])
      end
    end

    describe "tenant and project (§6.3)" do
      it "leaves out another company's entry, a discarded one and a missing one, as the caller's selection does" do
        mine = owned!
        theirs = entry!(company_id: copper_kettle)
        discarded = owned!(discarded_at: Time.current)

        bulk_move([mine.id, theirs.id, discarded.id, Entry.maximum(:id) + 1])

        expect(body).to include("moved_ids" => [mine.id], "skipped_ids" => [])
        expect(body.fetch("entries").pluck("id")).to eq([mine.id])
        expect([theirs.reload.version, discarded.reload.version]).to eq([1, 1])
      end

      it "answers a request that names none of the company's kept entries with nothing moved" do
        theirs = entry!(company_id: copper_kettle)

        bulk_move([theirs.id])

        expect(response).to have_http_status(:ok)
        expect(body).to eq("moved_ids" => [], "skipped_ids" => [], "entries" => [])
      end

      it "refuses a target project other than the token's, or one of another company, moving none" do
        entry = owned!

        bulk_move([entry.id], { "project_id" => 11 })
        expect_problem(403, "forbidden")

        bulk_move([entry.id], key: "key-2", project: target_project.merge("company_id" => copper_kettle))
        expect_problem(403, "forbidden")

        bulk_move([entry.id], key: "key-3", project: nil)
        expect_problem(403, "forbidden")

        expect_unchanged(entry)
      end
    end

    it "refuses a stale generation and a moving owner, changing nothing (§10.1)" do
      entry = owned!

      bulk_move([entry.id], carried: generation - 1)
      expect_problem(409, "stale-generation")

      Ownership.current.update!(state: "closed")
      bulk_move([entry.id])
      expect_problem(503, "ownership-moving")

      expect_unchanged(entry)
    end

    it "replays the stored answer for the same key and request, and refuses the key for another (§9.4)" do
      entry = owned!
      bulk_move([entry.id])
      first = body

      bulk_move([entry.id])
      expect(body).to eq(first)
      expect(entry.reload.version).to eq(2)

      bulk_move([entry.id], { "project_id" => 12 }, project: non_billable_project)
      expect_problem(409, "idempotency-conflict")
      expect(entry.reload.project_id).to eq(13)
    end

    it "refuses a body the contract does not allow" do
      entry = owned!

      bulk_move([])
      expect_problem(400, "invalid-request")

      bulk_move([entry.id], { "project_id" => nil })
      expect_problem(400, "invalid-request")

      bulk_move([entry.id, entry.id])
      expect_problem(400, "invalid-request")

      bulk_move([entry.id], { "project_id" => 13, "note" => "x" })
      expect_problem(400, "invalid-request")

      expect_unchanged(entry)
    end
  end

  describe "POST /internal/v1/entries/bulk_discard" do
    it "discards each named entry as its next version, with its audit row and outbox snapshot" do
      first, second = owned!, owned!

      bulk_discard([second.id, first.id])

      expect(response).to have_http_status(:ok)
      expect(contract_errors("entry_api", "#/$defs/bulk_discard_response", body)).to be_empty
      expect(body).to eq("discarded_ids" => [first.id, second.id])
      [first, second].each do |entry|
        entry.reload
        expect(entry).to have_attributes(version: 2, discarded_at: be_present)
        expect(entry.audits.sole).to have_attributes(
          action: "update", version: 2, writer: "bulk",
          audited_changes: { "discarded_at" => [nil, Entry.contract_value("discarded_at", entry.discarded_at)] }
        )
        expect(entry.outbox_snapshots.sole.snapshot).to eq(OutboxSnapshot.of(entry))
      end
    end

    it "lets an employee discard a locked entry, as today's discard runs no rule, and keeps its reservation" do
      entry = owned!.tap { |row| reservation!(row, invoice_id: 3) }

      bulk_discard([entry.id], role: "employee")

      expect(body).to eq("discarded_ids" => [entry.id])
      expect(entry.reload.discarded_at).to be_present
      expect(entry.reservations.sole).to have_attributes(invoice_id: 3, disposition: "active", edit_lock: true)
    end

    it "refuses the whole request as entry-locked for a billed entry, or an employee's entry outside the window (A9)" do
      billed = owned!(bill_status: "billed")
      stale = owned!(work_date: Date.current - 8)
      free = owned!

      bulk_discard([free.id, billed.id], role: "owner")
      expect_problem(403, "entry-locked")
      expect(body.fetch("detail")).to include("(A3)")

      bulk_discard([free.id, stale.id], key: "key-2", role: "employee")
      expect_problem(403, "entry-locked")
      expect(body.fetch("detail")).to include("(A4)")

      expect(Entry.kept.count).to eq(3)
      expect_unchanged(free, stale)
    end

    it "leaves out another company's entry, a discarded one and a missing one" do
      mine = owned!
      theirs = entry!(company_id: copper_kettle)
      discarded = owned!(discarded_at: 1.day.ago)

      bulk_discard([mine.id, theirs.id, discarded.id, Entry.maximum(:id) + 1])

      expect(body).to eq("discarded_ids" => [mine.id])
      expect(theirs.reload.discarded_at).to be_nil
      expect(discarded.reload.version).to eq(1)
    end

    it "replays a retry after the entries are gone instead of answering nothing discarded (§9.4)" do
      entry = owned!
      bulk_discard([entry.id])
      first = body

      bulk_discard([entry.id])

      expect(body).to eq(first)
      expect(entry.reload.version).to eq(2)
    end

    it "refuses a body, a stale generation and a moving owner, changing nothing" do
      entry = owned!

      bulk_discard([entry.id], { "project_id" => 13 })
      expect_problem(400, "invalid-request")

      bulk_discard([])
      expect_problem(400, "invalid-request")

      bulk_discard([entry.id], carried: generation + 1)
      expect_problem(409, "stale-generation")

      Ownership.current.update!(state: "frozen")
      bulk_discard([entry.id])
      expect_problem(503, "ownership-moving")

      expect_unchanged(entry)
    end
  end
end
