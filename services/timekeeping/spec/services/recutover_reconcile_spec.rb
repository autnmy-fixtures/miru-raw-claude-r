# frozen_string_literal: true

require "rails_helper"

# Step 6 of the re-cutover on Timekeeping's side
# (docs/architecture/timekeeping-soa.md §10.2 step 6, §10.5 step 6, §10.4):
# what Timekeeping holds once RecutoverLoad has loaded the checkpoint taken
# out of the prepared application, compared, exactly and part by part, with
# that same checkpoint.
RSpec.describe RecutoverReconcile do
  include_context "a re-cutover checkpoint"

  def reconcile!(checkpoint = self.checkpoint) = described_class.call(checkpoint)

  def loaded!
    checkpoint.tap { |taken| RecutoverLoad.call(taken) }
  end

  def receipt(invoice_id) = ReservationOperation.where(invoice_id:)

  describe "where the handoff must be" do
    {
      "admission still open" => { state: "open" },
      "admission closed, not yet frozen (settle may still be running)" => { state: "closed" },
      "frozen at another generation" => { generation: 7 },
      "frozen while legacy is the outgoing owner (the first cutover)" => { owner: "legacy" },
      "frozen while Timekeeping is the outgoing owner (a rollback)" => { owner: "timekeeping" }
    }.each do |name, ownership|
      it "refuses with #{name}, and changes nothing" do
        loaded!
        ownership!(**ownership)
        before = held_rows

        expect { reconcile! }.to raise_error(described_class::OutOfStep, /reconcile expects .*nothing changed/)
        expect(held_rows).to eq(before)
      end
    end

    it "holds the record FOR SHARE before it reads anything else" do
      loaded!
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
        statements << payload[:sql] unless payload[:name] == "SCHEMA" || payload[:sql].match?(/\A(BEGIN|COMMIT|SAVEPOINT|RELEASE)/)
      end

      reconcile!

      ActiveSupport::Notifications.unsubscribe(subscriber)
      first_read = statements.index { |sql| sql.include?("FROM \"ownerships\"") && sql.include?("FOR SHARE") }
      expect(first_read).not_to be_nil
      expect(statements.first(first_read)).to all(satisfy { |sql| !sql.match?(/"(entries|reservations|entry_audits|reservation_operations|idempotency_receipts)"/) })
    end
  end

  describe "after the load" do
    it "agrees, and answers how many rows of each part it reconciled" do
      loaded!

      expect(reconcile!).to eq(
        described_class::Reconciled.new(entries: 6, reservations: 4, entry_audits: 6, reservation_operations: 6, idempotency_receipts: 3)
      )
    end

    it "does not depend on the order the checkpoint carries its rows in" do
      loaded!
      shuffled = checkpoint.with(
        **%i[entries reservations entry_audits reservation_operations idempotency_receipts].index_with { |part| checkpoint.public_send(part).reverse }
      )

      expect { reconcile!(shuffled) }.not_to raise_error
    end

    it "writes nothing, and leaves the record frozen for the fence to flip" do
      loaded!
      before = held_rows

      reconcile!
      reconcile!

      expect(held_rows).to eq(before)
      expect(Ownership.current.summary).to eq("generation 6, owner monolith, state frozen")
    end
  end

  # A resumed handoff that skipped the load, or a load lost on the way:
  # Timekeeping still holds what it held at the rollback, which is not what
  # the prepared application handed over.
  it "finds every part the load would have changed when it never ran" do
    checkpoint
    before = held_rows

    expect { reconcile! }.to raise_error(described_class::Differs) do |error|
      expect(error.lists).to eq(
        entry_missing: [240],
        entry_differs: [101, 102],
        entry_audit_missing: [14, 15, 16],
        reservation_operation_missing: ["501/#{released_draft_operation}", "602/#{new_draft_operation}", "603/#{aborted_operation}"],
        idempotency_receipt_missing: ["2/web-2"],
        reservations_differ: [101, 240]
      )
    end
    expect(held_rows).to eq(before)
  end

  # Each changes one thing in what Timekeeping holds after the load, as a
  # write that slipped past the fence would, so only the checks named find it.
  describe "what Timekeeping holds after the load, changed" do
    {
      "an entry column" => [
        -> { Entry.where(id: 230).update_all(note: "rewritten") },
        { entry_differs: [230] }
      ],
      "an entry's version" => [
        -> { Entry.where(id: 103).update_all(version: 3) },
        { entry_differs: [103] }
      ],
      "an entry the checkpoint does not carry" => [
        -> { entry!(company_id: fork_and_leaf, id: 105, created_at:, updated_at:) },
        { entry_unexpected: [105] }
      ],
      "a reservation's disposition, which leaves locked as it was" => [
        -> { Reservation.where(entry_id: 103).update_all(disposition: "active") },
        { reservations_differ: [103] }
      ],
      "a reservation's edit lock, which changes the derived locked too (§7.1)" => [
        -> { Reservation.where(entry_id: 102).update_all(edit_lock: true) },
        { entry_differs: [102], reservations_differ: [102] }
      ],
      "a reservation the checkpoint does not carry: an F2 release undone" => [
        -> { reservation!(Entry.find(101), invoice_id: 501) },
        { entry_differs: [101], reservations_differ: [101] }
      ],
      "an audit row column" => [
        -> { EntryAudit.where(id: 16).update_all(actor: "user:8") },
        { entry_audit_differs: [16] }
      ],
      "an audit row gone" => [
        -> { EntryAudit.where(id: 15).delete_all },
        { entry_audit_missing: [15] }
      ],
      "an audit row the checkpoint does not carry" => [
        -> {
          EntryAudit.create!(
            id: 17, entry_id: 240, company_id: copper_kettle, action: "update", version: 3, actor: "user:7", writer: "web",
            request_id: "req-17", audited_changes: {}, created_at:
          )
        },
        { entry_audit_unexpected: [17] }
      ],
      "an operation receipt's outcome" => [
        -> { receipt(601).update_all(state: "aborted") },
        { reservation_operation_differs: ["601/3d6f4e2a-8b1c-4d5e-9f0a-7b6c5d4e3f2a"] }
      ],
      "an operation receipt gone" => [
        -> { receipt(701).delete_all },
        { reservation_operation_missing: ["701/8f14e45f-ceea-467f-a0e3-b4a1c3d2e5f6"] }
      ],
      "an operation receipt the checkpoint does not carry" => [
        -> { ReservationOperation.create!(invoice_id: 702, operation_id: "a87ff679-a2f3-471d-8f6b-0f5c1f6f2e3b", state: "aborted", created_at:, updated_at:) },
        { reservation_operation_unexpected: ["702/a87ff679-a2f3-471d-8f6b-0f5c1f6f2e3b"] }
      ],
      "an idempotency receipt's stored answer" => [
        -> { IdempotencyReceipt.where(company_id: fork_and_leaf, key: "web-1").update_all(response: {}) },
        { idempotency_receipt_differs: ["1/web-1"] }
      ],
      "an idempotency receipt gone" => [
        -> { IdempotencyReceipt.where(company_id: copper_kettle, key: "web-2").delete_all },
        { idempotency_receipt_missing: ["2/web-2"] }
      ],
      "an idempotency receipt the checkpoint does not carry" => [
        -> { IdempotencyReceipt.create!(company_id: fork_and_leaf, key: "web-9", request_digest: "d9", status: 201, response: {}, created_at:) },
        { idempotency_receipt_unexpected: ["1/web-9"] }
      ]
    }.each do |name, (change, lists)|
      it "finds #{name}, listing it, and changes nothing" do
        loaded!
        instance_exec(&change)
        before = held_rows

        expect { reconcile! }.to raise_error(described_class::Differs) { |error| expect(error.lists).to eq(lists) }
        expect(held_rows).to eq(before)
      end
    end
  end

  describe "a checkpoint other than the one loaded" do
    it "finds an entry it carries that Timekeeping does not hold" do
      loaded!
      extra = checkpoint.entries.last.merge("id" => 250, "locked" => false)

      expect { reconcile!(checkpoint.with(entries: checkpoint.entries + [extra])) }
        .to raise_error(described_class::Differs) { |error| expect(error.lists).to eq(entry_missing: [250]) }
    end

    it "finds a duration carried one digit off: the comparison is exact (§8 item 1)" do
      loaded!
      off = checkpoint.entries.map { |entry| entry["id"] == 102 ? entry.merge("duration" => 479.99998) : entry }

      expect { reconcile!(checkpoint.with(entries: off)) }
        .to raise_error(described_class::Differs) { |error| expect(error.lists).to eq(entry_differs: [102]) }
    end

    it "finds a timestamp carried in another form than the contract's" do
      loaded!
      audits = checkpoint.entry_audits.map { |audit| audit["id"] == 14 ? audit.merge("created_at" => Time.iso8601(later)) : audit }

      expect { reconcile!(checkpoint.with(entry_audits: audits)) }
        .to raise_error(described_class::Differs) { |error| expect(error.lists).to eq(entry_audit_differs: [14]) }
    end
  end

  it "raises the first cutover's Differs, so the handoff API answers both as checkpoint-differs, and says why" do
    loaded!
    Entry.where(id: 230).update_all(note: "rewritten")

    expect { reconcile! }.to raise_error(
      CheckpointReconcile::Differs, "Timekeeping checkpoint reconcile: entry_differs 230; abort the handoff"
    )
  end
end
