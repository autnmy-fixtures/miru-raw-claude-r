# frozen_string_literal: true

require "rails_helper"

# The invoice operation intent ledger of docs/architecture/timekeeping-soa.md
# §9.1 and the save order of §9.2, from the ledger's side. Across connections
# (recovery waiting for a save's transaction) is
# invoice_operation_recovery_spec.rb.
RSpec.describe Timekeeping::InvoiceOperation, type: :model do
  include TimekeepingOwnershipStates

  let(:invoice_id) { 501 }

  def open_intent(**attributes)
    described_class.open!(invoice_id:, company_id: 42, kind: :save, entry_ids: [101, 102], **attributes)
  end

  # The invoice transaction of §9.2 step 3: a savepoint, as a request runs in
  # its own transaction.
  def in_invoice_transaction(&)
    ActiveRecord::Base.transaction(requires_new: true, &)
  end

  describe ".open! (§9.2 step 1)" do
    it "records a pending, undelivered intent with a fresh operation id and the admitted generation" do
      set_timekeeping_ownership!(generation: 3, owner: "timekeeping", state: "open")

      intent = open_intent

      expect(intent.reload).to have_attributes(
        invoice_id:, company_id: 42, kind: "save", entry_ids: [101, 102],
        state: "pending", generation: 3, delivered_at: nil, operation_id: a_string_matching(/\A\h{8}-\h{4}-/)
      )
    end

    it "gives every intent its own operation id" do
      first = open_intent
      first.record_failure!

      expect(open_intent.operation_id).not_to eq(first.operation_id)
    end

    it "is the per-invoice serialization lock: a second operation of the invoice is refused while one is pending (§9.1)" do
      open_intent

      aggregate_failures do
        expect { open_intent(kind: :discard, entry_ids: []) }.to raise_error(described_class::Busy, /invoice 501 has an operation still pending/)
        expect(described_class.where(invoice_id:).count).to eq(1)
        expect { described_class.open!(invoice_id: 502, company_id: 42, kind: :save) }.not_to raise_error
      end
    end

    it "admits the next operation of the invoice once the pending one has an outcome" do
      open_intent.record_failure!
      second = open_intent
      in_invoice_transaction { second.succeed! }

      expect { open_intent }.not_to raise_error
    end

    it "works where no invoice row is left to lock: an intent for a deleted invoice" do
      expect { described_class.open!(invoice_id: Invoice.maximum(:id).to_i + 1_000, company_id: 42, kind: :destroy) }.not_to raise_error
    end

    TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.reject { |_, attributes| attributes[:state] == "open" }.each do |label, attributes|
      it "is refused as ownership moving, and records nothing, when #{label}" do
        set_timekeeping_ownership!(attributes)

        expect { open_intent }.to raise_error(Timekeeping::Ownership::Moving)
        expect(described_class.count).to eq(0)
      end
    end

    it "refuses to open inside another transaction, where it would not be durable before prepare" do
      expect { in_invoice_transaction { open_intent } }.to raise_error(described_class::TransactionOrder, /must commit on its own/)
      expect(described_class.count).to eq(0)
    end

    it "lets any other unique violation through" do
      taken = open_intent.operation_id
      allow(SecureRandom).to receive(:uuid).and_return(taken)

      expect { described_class.open!(invoice_id: 502, company_id: 42, kind: :save) }
        .to raise_error(ActiveRecord::RecordNotUnique, /index_invoice_operations_on_operation_id/)
    end
  end

  describe "#succeed! (§9.2 step 3)" do
    it "records success inside the invoice transaction" do
      intent = open_intent

      in_invoice_transaction { intent.succeed! }

      expect(intent.reload).to have_attributes(state: "succeeded", delivered_at: nil)
    end

    it "commits or rolls back with the invoice change" do
      intent = open_intent

      in_invoice_transaction do
        intent.succeed!
        raise ActiveRecord::Rollback
      end

      expect(intent.reload.state).to eq("pending")
    end

    it "refuses with a retryable error once recovery has resolved the intent, so the invoice change rolls back" do
      intent = open_intent
      described_class.find(intent.id).record_failure!

      expect { in_invoice_transaction { intent.succeed! } }.to raise_error(described_class::NoLongerPending, /already resolved as failed/)
      expect(intent.reload.state).to eq("failed")
    end

    it "refuses outside the invoice transaction, where success would not commit with the change" do
      intent = open_intent

      expect { intent.succeed! }.to raise_error(described_class::TransactionOrder, /inside the invoice transaction/)
      expect(intent.reload.state).to eq("pending")
    end
  end

  describe "#record_failure! (§9.2 step 4 and recovery)" do
    it "records failed for a pending intent, which queues abort in the same row" do
      intent = open_intent

      aggregate_failures do
        expect(intent.record_failure!).to eq("failed")
        expect(described_class.undelivered).to contain_exactly(intent)
        expect(intent.reload.delivery).to eq(:abort)
      end
    end

    it "leaves a save that recorded success first alone: commit is already queued" do
      intent = open_intent
      in_invoice_transaction { intent.succeed! }

      aggregate_failures do
        expect(described_class.find(intent.id).record_failure!).to eq("succeeded")
        expect(intent.reload.delivery).to eq(:commit)
      end
    end

    it "is idempotent" do
      intent = open_intent
      intent.record_failure!

      expect { expect(intent.record_failure!).to eq("failed") }.not_to change { intent.reload.updated_at }
    end
  end

  describe ".recover!" do
    it "resolves only the intents pending since before the cut-off, and never a recorded outcome" do
      stale = travel_to(2.minutes.ago) { open_intent }
      stale_succeeded = travel_to(2.minutes.ago) do
        described_class.open!(invoice_id: 502, company_id: 42, kind: :save).tap { |intent| in_invoice_transaction { intent.succeed! } }
      end
      fresh = described_class.open!(invoice_id: 503, company_id: 42, kind: :discard)

      outcomes = described_class.recover!(before: 1.minute.ago)

      aggregate_failures do
        expect(outcomes).to eq(stale.operation_id => "failed")
        expect([stale, stale_succeeded, fresh].map { |intent| intent.reload.state }).to eq(%w[failed succeeded pending])
      end
    end
  end

  describe "#reconcile (§9.2 step 3, prepare answered with a terminal receipt)" do
    def intent_in(state)
      open_intent.tap do |intent|
        { "succeeded" => -> { in_invoice_transaction { intent.succeed! } }, "failed" => -> { intent.record_failure! }, "pending" => -> { } }
          .fetch(state).call
      end
    end

    {
      %w[committed succeeded] => :succeeded,
      %w[aborted failed] => :failed,
      %w[committed failed] => :unreconciled,
      %w[aborted succeeded] => :unreconciled,
      %w[committed pending] => :unreconciled,
      %w[aborted pending] => :unreconciled
    }.each do |(receipt, intent_state), result|
      it "answers #{result} for a #{receipt} receipt and an intent #{intent_state}" do
        expect(intent_in(intent_state).reconcile(receipt)).to eq(result)
      end
    end

    it "reads the intent as stored, not as the caller last saw it" do
      intent = open_intent
      described_class.find(intent.id).record_failure!

      expect(intent.reconcile(:aborted)).to eq(:failed)
    end
  end

  describe "#resolves (§5.3)" do
    it "carries nothing for the first operation of an invoice" do
      expect(open_intent.resolves).to be_nil
    end

    it "carries the outcome of the latest earlier operation of the invoice not yet delivered, as its receipt" do
      committed = open_intent.tap { |intent| in_invoice_transaction { intent.succeed! } }
      expect(open_intent.resolves).to eq("operation_id" => committed.operation_id, "outcome" => "committed")

      aborted = described_class.state_pending.find_by!(invoice_id:).tap(&:record_failure!)
      expect(open_intent.resolves).to eq("operation_id" => aborted.operation_id, "outcome" => "aborted")
    end

    it "skips outcomes already delivered, other invoices' operations and later ones" do
      open_intent.tap(&:record_failure!).mark_delivered!
      described_class.open!(invoice_id: 502, company_id: 42, kind: :save).record_failure!
      intent = open_intent
      intent.record_failure!
      later = open_intent

      expect(intent.resolves).to be_nil
      expect(later.resolves).to eq("operation_id" => intent.operation_id, "outcome" => "aborted")
    end
  end

  describe "delivery (§9.1: the ledger is its own outbox)" do
    it "has nothing to deliver for a pending intent" do
      intent = open_intent

      aggregate_failures do
        expect(described_class.undelivered).to be_empty
        expect { intent.mark_delivered! }.to raise_error(ArgumentError, /pending: nothing to deliver/)
      end
    end

    it "marks an outcome delivered once, and then no longer lists it" do
      intent = open_intent
      intent.record_failure!

      intent.mark_delivered!
      delivered_at = intent.reload.delivered_at
      travel(1.minute) { intent.mark_delivered! }

      aggregate_failures do
        expect(intent.reload.delivered_at).to eq(delivered_at)
        expect(described_class.undelivered).to be_empty
      end
    end
  end

  describe "the table's backstops" do
    def refused(&)
      expect { ActiveRecord::Base.transaction(requires_new: true, &) }
    end

    def row(**attributes)
      { operation_id: SecureRandom.uuid, invoice_id: 900, company_id: 42, kind: "save", generation: 0, state: "failed" }.merge(attributes)
    end

    it "keeps one pending intent per invoice, beside any number of resolved ones" do
      described_class.create!(row(state: "succeeded"))
      described_class.create!(row(state: "failed"))
      described_class.create!(row(state: "pending"))

      refused { described_class.create!(row(state: "pending")) }.to raise_error(ActiveRecord::RecordNotUnique, /one_pending_per_invoice/)
    end

    it "never marks a pending intent delivered, and accepts only known kinds and states" do
      aggregate_failures do
        refused { described_class.create!(row(state: "pending", delivered_at: Time.current)) }.to raise_error(ActiveRecord::StatementInvalid, /pending_undelivered/)
        refused { described_class.create!(row(kind: "send")) }.to raise_error(ActiveRecord::StatementInvalid, /invoice_operations_kind/)
        refused { described_class.insert_all!([row(state: "committed")]) }.to raise_error(ActiveRecord::StatementInvalid, /invoice_operations_state/)
      end
    end

    it "has no foreign key to invoices: an intent survives its invoice's hard delete (§9.1)" do
      invoice = create(:invoice, status: :sent)
      intent = described_class.open!(invoice_id: invoice.id, company_id: invoice.company_id, kind: :destroy)

      invoice.destroy!

      expect(intent.reload.invoice_id).to eq(invoice.id)
    end
  end
end
