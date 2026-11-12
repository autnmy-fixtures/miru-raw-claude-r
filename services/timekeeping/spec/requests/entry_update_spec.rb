# frozen_string_literal: true

require "rails_helper"

# Entry update and discard (§5.2), provider side (§12.3): one mutating call
# each, admitted under the carried generation (§10.1), that holds the entry
# FOR UPDATE, checks A3-A5 against it (§6.2), and writes the entry's next
# version, its audit row, its outbox snapshot and its idempotency receipt in
# one transaction (§3.4), or nothing. Update runs TimesheetEntry's update
# rules, the edit lock among them (L1); discard runs none, as today's
# discard! runs none.
RSpec.describe "Entry API update and discard" do
  let(:fork_and_leaf) { 1 }
  let(:copper_kettle) { 2 }
  let(:generation) { 3 }

  let(:billable_project) { { "id" => 11, "company_id" => fork_and_leaf, "kept" => true, "billable" => true } }
  let(:other_billable_project) { { "id" => 13, "company_id" => fork_and_leaf, "kept" => true, "billable" => true } }
  let(:non_billable_project) { { "id" => 12, "company_id" => fork_and_leaf, "kept" => true, "billable" => false } }

  before { Ownership.create!(generation:, owner: "timekeeping", state: "open") }

  def body = JSON.parse(response.body)

  # An entry of user 7 in Fork & Leaf's billable project 11, worked today,
  # so it is inside every edit window.
  def owned!(**attributes) = entry!(company_id: fork_and_leaf, work_date: Date.current, note: "Before", **attributes)

  def mutating_headers(company_id: fork_and_leaf, key: "key-1", carried: generation, project: billable_project, **claims)
    entry_api_headers(company_id:, project:, **claims).merge(
      "Idempotency-Key" => key, "X-Ownership-Generation" => carried.to_s, "Content-Type" => "application/json"
    )
  end

  # The body is positional and always braced: Ruby folds a trailing
  # string-keyed hash into **headers otherwise.
  def update(entry, attributes = { "project_id" => 11, "note" => "After" }, **headers)
    patch "/internal/v1/entries/#{entry.id}", params: JSON.generate({ "entry" => attributes }), headers: mutating_headers(**headers)
  end

  def discard(entry, body = {}, **headers)
    delete "/internal/v1/entries/#{entry.id}", params: JSON.generate(body), headers: mutating_headers(**headers)
  end

  def expect_problem(status, slug)
    expect(response).to have_http_status(status)
    expect(response.media_type).to eq("application/problem+json")
    expect(body).to include("type" => "https://contracts.timekeeping.internal/problems/#{slug}", "status" => status)
    expect(contract_errors("common", "#/$defs/problem", body)).to be_empty
  end

  # Nothing changed: the entry as it was, and no audit, outbox or receipt row.
  def expect_unchanged(entry)
    expect(entry.reload).to have_attributes(version: 1, note: "Before", discarded_at: nil)
    expect([EntryAudit.count, OutboxSnapshot.count, IdempotencyReceipt.count]).to eq([0, 0, 0])
  end

  describe "PATCH /internal/v1/entries/{id}" do
    it "updates the entry as its next version and answers it as the contract states it" do
      entry = owned!

      update(entry, { "project_id" => 11, "note" => "After", "duration" => 45.0 })

      expect(response).to have_http_status(:ok)
      expect(contract_errors("entry_api", "#/$defs/entry_response", body)).to be_empty
      expect(body.fetch("entry")).to eq(entry.reload.to_contract)
      expect(body.fetch("entry")).to include("id" => entry.id, "note" => "After", "duration" => 45.0, "version" => 2)
    end

    it "writes one update audit row with each changed column as [before, after], and one outbox snapshot (§3.4)" do
      entry = owned!

      update(entry, { "project_id" => 13, "note" => "After", "bill_status" => "unbilled" }, project: other_billable_project)

      entry.reload
      expect(entry.audits.sole).to have_attributes(
        company_id: fork_and_leaf, action: "update", version: 2, actor: "user:7", writer: "web",
        request_id: "req-#{fork_and_leaf}", audited_changes: { "note" => %w[Before After], "project_id" => [11, 13] }
      )
      outbox = entry.outbox_snapshots.sole
      expect(outbox).to have_attributes(version: 2, request_id: "req-#{fork_and_leaf}")
      expect(contract_errors("entry_snapshot", "#/$defs/entry_snapshot", outbox.snapshot)).to be_empty
      expect(outbox.snapshot).to eq(OutboxSnapshot.of(entry))
    end

    it "writes nothing for an update that changes nothing, as today's update! saves nothing, and still answers it" do
      entry = owned!

      update(entry, { "project_id" => 11, "note" => "Before" })

      expect(response).to have_http_status(:ok)
      expect(body.dig("entry", "version")).to eq(1)
      expect([EntryAudit.count, OutboxSnapshot.count]).to eq([0, 0])
    end

    it "writes a snapshot and no audit row for a change to no audited column, as audited writes none" do
      entry = owned!

      update(entry, { "project_id" => 11, "external_run_id" => "run-1" })

      expect(entry.reload).to have_attributes(external_run_id: "run-1", version: 2)
      expect(EntryAudit.count).to eq(0)
      expect(entry.outbox_snapshots.sole.version).to eq(2)
    end

    describe "who may update (A3-A5, against the row the write holds)" do
      it "lets an owner or admin update anyone's entry, even outside the edit window" do
        entry = owned!(user_id: 9, work_date: Date.current - 30)

        update(entry, sub: "user:7", role: "owner")
        expect(response).to have_http_status(:ok)

        update(entry, { "project_id" => 11, "note" => "Admin" }, key: "key-2", role: "admin")
        expect(body.dig("entry", "note")).to eq("Admin")
      end

      it "refuses a billed entry to every role (A3)" do
        entry = owned!(bill_status: "billed")

        update(entry, role: "owner")

        expect_problem(403, "forbidden")
        expect(body.fetch("detail")).to include("(A3)")
        expect_unchanged(entry)
      end

      it "refuses an employee their entry older than the edit window (A4)" do
        entry = owned!(work_date: Date.current - 8)

        update(entry, role: "employee")

        expect_problem(403, "forbidden")
        expect(body.fetch("detail")).to include("(A4)")
        expect_unchanged(entry)
      end

      it "refuses an employee someone else's entry (A5)" do
        entry = owned!(user_id: 9)

        update(entry, role: "employee")

        expect_problem(403, "forbidden")
        expect(body.fetch("detail")).to include("(A5)")
        expect_unchanged(entry)
      end

      it "lets an employee mark their own entry billed (A11)" do
        entry = owned!

        update(entry, { "project_id" => 11, "bill_status" => "billed" }, role: "employee")

        expect(response).to have_http_status(:ok)
        expect(entry.reload.bill_status).to eq("billed")
      end
    end

    describe "the edit lock (L1), from the entry's reservations (§7.1)" do
      it "refuses an employee a locked entry with TimesheetEntry's message, as validation-failed" do
        entry = owned!.tap { |row| reservation!(row, invoice_id: 3) }

        update(entry, role: "employee")

        expect_problem(422, "validation-failed")
        expect(body.fetch("errors")).to eq("base" => [Entry::LOCKED_EDIT])
        expect_unchanged(entry)
      end

      it "locks for a retained reservation with edit_lock too, and not for an active one without it" do
        retained = owned!.tap { |row| reservation!(row, invoice_id: 3, disposition: "retained") }
        unlocked = owned!.tap { |row| reservation!(row, invoice_id: 4, edit_lock: false) }

        update(retained, role: "employee")
        expect_problem(422, "validation-failed")

        update(unlocked, key: "key-2", role: "employee")
        expect(response).to have_http_status(:ok)
      end

      it "does not stop an owner or admin" do
        entry = owned!.tap { |row| reservation!(row, invoice_id: 3) }

        update(entry, role: "admin")

        expect(response).to have_http_status(:ok)
        expect(body.dig("entry", "locked")).to be(true)
      end
    end

    describe "the model's update rules" do
      it "normalizes the metadata and infers the source, as on create" do
        entry = owned!

        update(entry, { "project_id" => 11, "source" => "cli", "source_metadata" => { "mcp_server" => " miru ", "other" => "dropped" } }, writer: "cli")

        expect(body.fetch("entry")).to include("source" => "mcp", "source_metadata" => { "mcp_server" => "miru" })
      end

      it "keeps an agent's entry waiting for review (A10)" do
        entry = owned!(agent_id: 5, review_status: "not_required")

        update(entry)

        expect(body.dig("entry", "review_status")).to eq("pending_review")
      end

      it "refuses an unbilled entry moved to a non-billable project, and a duration out of range, with today's messages" do
        entry = owned!

        update(entry, { "project_id" => 12 }, project: non_billable_project)
        expect_problem(422, "validation-failed")
        expect(body.fetch("errors")).to eq("base" => ["You can't create an unbilled entry for non-billable projects"])

        update(entry, { "project_id" => 11, "duration" => 6_000_000.5 }, key: "key-2")
        expect_problem(422, "validation-failed")
        expect(body.fetch("errors")).to eq("duration" => ["must be less than or equal to 6000000"])

        expect_unchanged(entry)
      end
    end

    describe "tenant and project (§6.3)" do
      it "answers another company's entry, a discarded one and a missing one as not-found" do
        theirs = entry!(company_id: copper_kettle, note: "Before")
        discarded = owned!(discarded_at: Time.current)

        [theirs.id, discarded.id, Entry.maximum(:id) + 1].each_with_index do |id, n|
          patch "/internal/v1/entries/#{id}", params: JSON.generate({ "entry" => { "project_id" => 11 } }), headers: mutating_headers(key: "key-#{n}")
          expect_problem(404, "not-found")
        end
        expect(theirs.reload.version).to eq(1)
      end

      it "refuses a project other than the token's, keeping the entry's own when the update names none" do
        entry = owned!

        update(entry, { "project_id" => 13 })
        expect_problem(403, "forbidden")

        update(entry, { "note" => "After" }, key: "key-2", project: other_billable_project)
        expect_problem(403, "forbidden")

        update(entry, { "note" => "After" }, key: "key-3", project: billable_project.merge("company_id" => copper_kettle))
        expect_problem(403, "forbidden")

        update(entry, { "note" => "After" }, key: "key-4")
        expect(response).to have_http_status(:ok)
      end
    end

    it "refuses a stale generation and a moving owner, changing nothing (§10.1)" do
      entry = owned!

      update(entry, carried: generation - 1)
      expect_problem(409, "stale-generation")

      Ownership.current.update!(state: "frozen")
      update(entry)
      expect_problem(503, "ownership-moving")

      expect_unchanged(entry)
    end

    it "replays the stored answer for the same key and request, and refuses the key for another (§9.4)" do
      entry = owned!
      update(entry)
      first = body

      update(entry)
      expect(body).to eq(first)
      expect(entry.reload.version).to eq(2)

      update(entry, { "project_id" => 11, "note" => "Else" })
      expect_problem(409, "idempotency-conflict")
      expect(entry.reload.note).to eq("After")
    end

    it "refuses a body the contract does not allow, and has no PUT" do
      entry = owned!

      update(entry, {})
      expect_problem(400, "invalid-request")

      update(entry, { "agent_id" => 5 })
      expect_problem(400, "invalid-request")

      put "/internal/v1/entries/#{entry.id}", params: JSON.generate({ "entry" => { "note" => "After" } }), headers: mutating_headers
      expect_problem(404, "not-found")

      expect_unchanged(entry)
    end
  end

  describe "DELETE /internal/v1/entries/{id}" do
    it "discards the entry as its next version, with its audit row and outbox snapshot" do
      entry = owned!

      discard(entry)

      expect(response).to have_http_status(:ok)
      expect(contract_errors("entry_api", "#/$defs/entry_response", body)).to be_empty
      entry.reload
      expect(entry).to have_attributes(version: 2, discarded_at: be_present)
      expect(body.fetch("entry")).to eq(entry.to_contract)
      expect(entry.audits.sole).to have_attributes(
        action: "update", version: 2, writer: "web",
        audited_changes: { "discarded_at" => [nil, Entry.contract_value("discarded_at", entry.discarded_at)] }
      )
      expect(entry.outbox_snapshots.sole.snapshot.dig("data", "discarded_at")).to eq(body.dig("entry", "discarded_at"))
    end

    it "lets an employee discard their own locked entry, as today's discard! runs no validation, and keeps its reservation" do
      entry = owned!.tap { |row| reservation!(row, invoice_id: 3) }

      discard(entry, role: "employee")

      expect(response).to have_http_status(:ok)
      expect(body.fetch("entry")).to include("locked" => true, "discarded_at" => be_present)
      expect(entry.reservations.sole).to have_attributes(invoice_id: 3, disposition: "active", edit_lock: true)
    end

    it "checks A3-A5 as update does" do
      billed = owned!(bill_status: "billed")
      stale = owned!(work_date: Date.current - 8)
      someone_elses = owned!(user_id: 9)

      [billed, stale, someone_elses].each_with_index do |entry, n|
        discard(entry, key: "key-#{n}", role: "employee")
        expect_problem(403, "forbidden")
      end
      expect(Entry.kept.count).to eq(3)
    end

    it "answers an entry already discarded, or another company's, as not-found" do
      discarded = owned!(discarded_at: Time.current)
      theirs = entry!(company_id: copper_kettle)

      discard(discarded)
      expect_problem(404, "not-found")

      discard(theirs, key: "key-2")
      expect_problem(404, "not-found")
      expect(theirs.reload.discarded_at).to be_nil
    end

    it "replays a retry after the entry is gone instead of answering not-found (§9.4)" do
      entry = owned!
      discard(entry)
      first = body

      discard(entry)

      expect(response).to have_http_status(:ok)
      expect(body).to eq(first)
      expect(entry.reload.version).to eq(2)
    end

    it "refuses a body, a stale generation and a moving owner, changing nothing" do
      entry = owned!

      discard(entry, { "reason" => "x" })
      expect_problem(400, "invalid-request")

      discard(entry, carried: generation + 1)
      expect_problem(409, "stale-generation")

      Ownership.current.update!(state: "closed")
      discard(entry)
      expect_problem(503, "ownership-moving")

      expect_unchanged(entry)
    end
  end
end
