# frozen_string_literal: true

require "rails_helper"

# The invoice reservation boundary of docs/architecture/timekeeping-soa.md
# §3.1 (W7) and §7, in the save order of §9.2, against the consumer-side fake
# of Timekeeping (§12.3). The §9.3 rows it owns: Timekeeping down at prepare,
# a refused prepare (F1, L8), an earlier operation unresolved, a lost response
# on prepare, a crash or rollback before the invoice commits, a prepare after
# its operation is terminal, and a stale generation. The §12.4 terminal-receipt
# replays are here too.
RSpec.describe Timekeeping::InvoiceBoundary do
  include TimekeepingContracts::ReservationDriver

  subject(:boundary) { described_class.new(pause: ->(attempt) { pauses << attempt }) }

  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: 1).install! }
  let(:pauses) { [] }
  let(:company) { create(:company) }
  let(:other_company) { create(:company) }
  let(:invoice) { create(:invoice, company:, status: :sent, reference: "before") }
  let(:entry_id) { seed_entry(company)["id"] }
  let(:worker) { Timekeeping::InvoiceOperationWorker.new }

  around do |example|
    config = Rails.configuration.x.timekeeping
    url, key = config.url, config.token_key
    config.url, config.token_key = TimekeepingContracts::FakeTimekeeping::URL, TimekeepingContracts::TEST_TOKEN_KEY
    example.run
  ensure
    config.url, config.token_key = url, key
  end

  before do
    invoice
    set_timekeeping_ownership!(generation: 1, owner: "timekeeping", state: "open")
  end

  after { expect(fake.violations).to be_empty }

  def seed_entry(owner)
    fake.seed_entry(company_id: owner.id, project_id: 7, user_id: 3, duration: 90.7, work_date: "2026-11-02")
  end

  def change(entry_ids: [entry_id], invoice_state: :non_draft, kind: :save, target: invoice)
    described_class::Change.new(invoice_id: target.id, company_id: target.company_id, kind:, invoice_state:, entry_ids:)
  end

  # The invoice change of a save: a column the reservation never reads, so
  # the spec sees whether the invoice transaction committed.
  def rename(reference = "after")
    ->(_entries) { invoice.update!(reference:) }
  end

  def intents = Timekeeping::InvoiceOperation.order(:id).to_a

  def prepare_calls = fake.calls.select { |call| call.operation == :prepare }

  def failure(reason, retryable:)
    an_instance_of(described_class::Failed).and(having_attributes(reason:, retryable:))
  end

  describe "under the timekeeping owner" do
    it "opens the intent, prepares the desired set, runs the change and records success with it (§9.2 steps 1-3)" do
      received = nil

      result = boundary.run(change) do |entries|
        received = entries
        invoice.update!(reference: "after")
      end

      intent = intents.sole
      aggregate_failures do
        expect(result).to have_attributes(intent:, replayed: false, value: true)
        expect(intent).to have_attributes(state: "succeeded", kind: "save", entry_ids: [entry_id], company_id: company.id, generation: 1, delivered_at: nil)
        expect(invoice.reload.reference).to eq("after")
        expect(received).to eq([Timekeeping::ReservationClient::PreparedEntry.new(
          id: entry_id, company_id: company.id, project_id: 7, user_id: 3, duration: 90.7, work_date: "2026-11-02", version: 1
        )])
        expect(fake.holding(entry_id).state).to eq(:provisional)
      end
    end

    it "sends prepare under the intent's generation and operation id, and leaves commit to the worker (§9.2 step 4)" do
      result = boundary.run(change(invoice_state: :draft), &rename)

      call = prepare_calls.sole
      expect(call.params).to eq("invoice_id" => invoice.id.to_s, "operation_id" => result.intent.operation_id)
      expect(call.input).to eq(
        "company_id" => company.id, "generation" => 1, "kind" => "save", "invoice_state" => "draft",
        "entry_ids" => [entry_id], "resolves" => nil
      )
      expect(call.claims).to include("sub" => "system", "company_id" => company.id, "writer" => "invoice")
      expect(fake.calls.map(&:operation)).to eq([:prepare])

      expect(worker.run.delivered).to eq([result.intent.operation_id])
      expect(fake.holding(entry_id).state).to eq(:committed)
    end

    it "prepares discard and destroy with an empty desired set" do
      boundary.run(change(kind: :discard, entry_ids: [])) { :discarded }

      expect(prepare_calls.sole.input).to include("kind" => "discard", "entry_ids" => [])
      expect(intents.sole).to have_attributes(kind: "discard", entry_ids: [], state: "succeeded")
    end

    it "carries the outcome of the invoice's earlier undelivered operation in resolves (§5.3)" do
      first = boundary.run(change, &rename).intent
      expect { boundary.run(change) { raise ActiveRecord::RecordInvalid } }.to raise_error(ActiveRecord::RecordInvalid)
      failed = intents.last

      boundary.run(change, &rename)

      expect(prepare_calls.map { |call| call.input.fetch("resolves") }).to eq([
        nil,
        { "operation_id" => first.operation_id, "outcome" => "committed" },
        { "operation_id" => failed.operation_id, "outcome" => "aborted" }
      ])
      expect(fake.holding(entry_id).state).to eq(:committed)
    end

    it "carries no outcome once the earlier one is delivered" do
      boundary.run(change, &rename)
      worker.run

      boundary.run(change, &rename)

      expect(prepare_calls.last.input.fetch("resolves")).to be_nil
    end

    describe "a refused prepare" do
      it "fails an explicit double allocation with the refused entry, before the change runs (F1)" do
        other = create(:invoice, company:, status: :sent)
        boundary.run(change(target: other)) { :reserved }

        expect { boundary.run(change, &rename) }.to raise_error(failure(:reservation_refused, retryable: false)) { |error|
          expect(error.refused).to eq([TimekeepingReservations::Refusal.new(entry_id:, reason: :on_other_invoice)])
        }
        expect(intents.last.state).to eq("failed")
        expect(invoice.reload.reference).to eq("before")
        expect(prepare_calls.size).to eq(2)
      end

      it "refuses the other tenant's entry and an entry that does not exist (L8, §6.3)" do
        foreign = seed_entry(other_company)["id"]

        expect { boundary.run(change(entry_ids: [foreign, 9_999]), &rename) }.to raise_error(described_class::Failed) { |error|
          expect(error.refused).to eq([
            TimekeepingReservations::Refusal.new(entry_id: foreign, reason: :wrong_company),
            TimekeepingReservations::Refusal.new(entry_id: 9_999, reason: :not_found)
          ])
        }
        expect(fake.holding(foreign)).to be_nil
      end

      it "fails as retryable while Timekeeping holds an earlier operation of the invoice unresolved" do
        stray = Timekeeping::InvoiceOperation.new(
          operation_id: SecureRandom.uuid, invoice_id: invoice.id, company_id: company.id, kind: "save", entry_ids: [entry_id], generation: 1
        )
        prepare_in_timekeeping(stray)

        expect { boundary.run(change, &rename) }.to raise_error(failure(:operation_unresolved, retryable: true))
        expect(intents.sole.state).to eq("failed")
      end

      it "fails on a stale generation, without retrying it" do
        fake.generation = 2

        expect { boundary.run(change, &rename) }.to raise_error(failure(:stale_generation, retryable: false))
        expect([intents.sole.state, prepare_calls.size, pauses]).to eq(["failed", 0, []])
      end
    end

    describe "a failed invoice change" do
      it "rolls the change back with the failure, records it, and re-raises it; the worker then aborts" do
        expect {
          boundary.run(change) do
            invoice.update!(reference: "after")
            raise ActiveRecord::RecordInvalid
          end
        }.to raise_error(ActiveRecord::RecordInvalid)

        intent = intents.sole
        expect([intent.state, invoice.reload.reference, fake.holding(entry_id).state]).to eq(["failed", "before", :provisional])

        expect(worker.run.delivered).to eq([intent.operation_id])
        expect(fake.holding(entry_id)).to be_nil
      end

      it "fails a change that rolled back without an error" do
        expect {
          boundary.run(change) do
            invoice.update!(reference: "after")
            raise ActiveRecord::Rollback
          end
        }.to raise_error(failure(:rolled_back, retryable: false))
        expect([intents.sole.state, invoice.reload.reference]).to eq(["failed", "before"])
      end

      it "rolls the change back when recovery resolved the intent first (§9.2 step 3)" do
        expect {
          boundary.run(change) do
            invoice.update!(reference: "after")
            Timekeeping::InvoiceOperation.state_pending.update_all(state: "failed")
          end
        }.to raise_error(Timekeeping::InvoiceOperation::NoLongerPending)
        expect([intents.sole.state, invoice.reload.reference]).to eq(["failed", "before"])
      end
    end

    describe "Timekeeping unreachable at prepare" do
      it "retries a lost response with the same operation, and the save goes through (§9.4)" do
        fake.lose_next_response(:prepare)

        result = boundary.run(change, &rename)

        expect(result.intent.state).to eq("succeeded")
        expect(prepare_calls.map { |call| call.params.fetch("operation_id") }.uniq).to eq([result.intent.operation_id])
        expect([prepare_calls.size, pauses]).to eq([2, [1]])
      end

      it "retries a 5xx problem" do
        fake.fail_next(:prepare, status: 503, slug: "ownership-moving", retryable: true)

        expect(boundary.run(change, &rename).intent.state).to eq("succeeded")
        expect(pauses).to eq([1])
      end

      it "fails as retryable after three attempts, with the intent failed and nothing changed (§9.3 Timekeeping down)" do
        WebMock::API.stub_request(:post, %r{/prepare\z}).to_raise(Errno::ECONNREFUSED)

        expect { boundary.run(change, &rename) }.to raise_error(failure(:unavailable, retryable: true))
        expect([intents.sole.state, invoice.reload.reference, pauses]).to eq(["failed", "before", [1, 2]])
      end

      it "records every lost answer as failed, so the worker aborts the reservation prepare left (§9.3 lost response)" do
        3.times { fake.lose_next_response(:prepare) }

        expect { boundary.run(change, &rename) }.to raise_error(failure(:unavailable, retryable: true))
        expect(fake.holding(entry_id).state).to eq(:provisional)

        worker.run
        expect(fake.holding(entry_id)).to be_nil
      end
    end

    describe "a prepare that answers a terminal receipt (§9.2 step 3, §12.4)" do
      it "returns the existing outcome of a committed save, and runs nothing again" do
        intent = boundary.run(change, &rename).intent
        worker.run

        result = boundary.perform(intent.reload, invoice_state: :non_draft) { raise "must not run" }

        expect(result).to eq(described_class::Result.new(intent:, value: nil, replayed: true))
        expect(intent.reload.state).to eq("succeeded")
      end

      it "fails the replay of an aborted save" do
        expect { boundary.run(change) { raise ActiveRecord::RecordInvalid } }.to raise_error(ActiveRecord::RecordInvalid)
        intent = intents.sole
        worker.run

        expect { boundary.perform(intent.reload, invoice_state: :non_draft) { raise "must not run" } }
          .to raise_error(failure(:aborted, retryable: false))
      end

      it "fails as retryable, changing nothing, when the intent is still pending and its operation committed" do
        intent = Timekeeping::InvoiceOperation.open!(invoice_id: invoice.id, company_id: company.id, kind: :save, entry_ids: [entry_id])
        prepare_in_timekeeping(intent)
        Timekeeping::ReservationClient.new.commit(intent)

        expect { boundary.perform(intent, invoice_state: :non_draft) { raise "must not run" } }
          .to raise_error(failure(:unreconciled, retryable: true))
        expect([intent.reload.state, invoice.reload.reference]).to eq(["pending", "before"])
      end
    end

    describe "the save order" do
      it "refuses to run inside an application transaction, before any intent is written" do
        expect { ActiveRecord::Base.transaction { boundary.run(change, &rename) } }
          .to raise_error(Timekeeping::InvoiceOperation::TransactionOrder)
        expect(intents).to be_empty
      end

      it "refuses a second operation of the invoice while one is pending (§9.1)" do
        Timekeeping::InvoiceOperation.open!(invoice_id: invoice.id, company_id: company.id, kind: :save, entry_ids: [])

        expect { boundary.run(change, &rename) }.to raise_error(Timekeeping::InvoiceOperation::Busy)
        expect(prepare_calls).to be_empty
      end

      it "refuses as moving when the generation was raised between choosing the owner and admission" do
        allow(Timekeeping::Ownership).to receive(:current).and_return(Timekeeping::Ownership.new(generation: 0, owner: "timekeeping", state: "open"))

        expect { boundary.run(change, &rename) }.to raise_error(Timekeeping::Ownership::Moving)
        expect([intents.sole.state, prepare_calls]).to eq(["failed", []])
      end
    end
  end

  describe "owners" do
    it "runs the change as today under the legacy owner: no intent, no prepare, no prepared entries" do
      set_timekeeping_ownership!(generation: 0, owner: "legacy", state: "open")
      received = :unset

      result = boundary.run(change) do |entries|
        received = entries
        :saved
      end

      expect(result).to eq(described_class::Result.new(intent: nil, value: :saved, replayed: false))
      expect([received, intents, fake.calls]).to eq([nil, [], []])
    end

    it "refuses under the monolith owner until its provider exists, before any intent is written" do
      set_timekeeping_ownership!(generation: 2, owner: "monolith", state: "open")

      expect { boundary.run(change, &rename) }.to raise_error(described_class::OwnerUnavailable, /owner monolith/)
      expect(intents).to be_empty
    end

    it "refuses as moving while a handoff has admission closed, before any intent is written" do
      set_timekeeping_ownership!(generation: 2, owner: "timekeeping", state: "closed")

      expect { boundary.run(change, &rename) }.to raise_error(Timekeeping::Ownership::Moving)
      expect(intents).to be_empty
    end
  end

  describe "Change" do
    it "keeps the desired set unique and refuses an unknown kind or invoice state" do
      expect(change(entry_ids: [3, 3, 4]).entry_ids).to eq([3, 4])
      expect { change(kind: :send) }.to raise_error(ArgumentError, /kind/)
      expect { change(invoice_state: :sent) }.to raise_error(ArgumentError, /invoice state/)
    end
  end
end
