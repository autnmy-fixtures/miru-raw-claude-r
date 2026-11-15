# frozen_string_literal: true

require "rails_helper"

# The `monolith` owner's side of the reservation API
# (docs/architecture/timekeeping-soa.md §5.3, §9.2, §10.5): prepare for the
# invoice reservation boundary, and commit and abort for the invoice
# operation worker, run in-process against the prepared application's
# reservation table, admitted under the intent's generation, and answered as
# Timekeeping::ReservationClient answers the `timekeeping` owner's calls, so
# the boundary and the worker read either owner one way.
RSpec.describe Timekeeping::LocalReservationClient do
  include_context "with two Timekeeping tenants"

  subject(:client) { described_class.new }

  let(:generation) { 2 }
  let(:company) { tenant_a.company }
  let(:local) { Timekeeping::LocalReservations.new(entries: Timekeeping::LocalEntries.new) }
  let(:first_id) { TimesheetEntry.maximum(:id).to_i + 1_000 }
  let(:entry) { held_entry(offset: 0) }
  let(:problem_pointer) { Timekeeping::InternalApi::PROBLEM }

  before do
    set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rolled back to the prepared application"))
  end

  # An entry the prepared application holds, which the projection does not.
  def held_entry(offset:, tenant: tenant_a)
    Timekeeping::Entry.create!(
      id: first_id + offset, company_id: tenant.company.id, project_id: tenant.project.id, user_id: tenant.employee.id,
      duration: 90.7, work_date: Date.new(2026, 11, 2), bill_status: "unbilled"
    )
  end

  def intent(entry_ids: [entry.id], invoice_id: 10, kind: "save", generation: self.generation, operation_id: SecureRandom.uuid)
    Timekeeping::InvoiceOperation.new(operation_id:, invoice_id:, company_id: company.id, kind:, entry_ids:, generation:)
  end

  def prepare(intent, invoice_state: :draft, resolves: nil)
    client.prepare(intent, invoice_state:, resolves:)
  end

  def reservations
    Timekeeping::Reservation.order(:entry_id, :invoice_id).pluck(:entry_id, :invoice_id, :state, :disposition, :edit_lock)
  end

  def receipt_of(intent)
    Timekeeping::ReservationOperation.find_by(invoice_id: intent.invoice_id, operation_id: intent.operation_id)&.state
  end

  def local_state
    [reservations, Timekeeping::ReservationOperation.order(:id).pluck(:operation_id, :state), Timekeeping::OutboxSnapshot.count]
  end

  def problem(slug, status:, retryable:)
    an_instance_of(Timekeeping::ReservationClient::Problem).and(having_attributes(type: slug, status:, retryable:))
  end

  describe "a prepare the local provider prepares" do
    it "answers the client's Prepared, with the desired set's facts in the desired set's order (L8)" do
      second = held_entry(offset: 1)

      answer = prepare(intent(entry_ids: [second.id, entry.id]))

      expect(answer).to eq(Timekeeping::ReservationClient::Prepared.new(entries: [second, entry].map { |held|
        Timekeeping::ReservationClient::PreparedEntry.new(
          id: held.id, company_id: company.id, project_id: tenant_a.project.id, user_id: tenant_a.employee.id,
          duration: 90.7, work_date: "2026-11-02", version: 2
        )
      }))
    end

    it "reserves the entries provisionally and registers the operation, as Timekeeping's prepare does" do
      prepared = intent

      prepare(prepared)

      expect(reservations).to eq([[entry.id, 10, "provisional", "active", true]])
      expect(receipt_of(prepared)).to eq("prepared")
      expect(entry.reload.outbox_snapshots.order(:version).last.snapshot.dig("data", "locked")).to be(true)
    end

    it "prepares a non-draft without the edit lock" do
      prepare(intent, invoice_state: :non_draft)

      expect(reservations).to eq([[entry.id, 10, "provisional", "active", false]])
    end

    it "prepares discard and destroy with an empty desired set" do
      expect(prepare(intent(kind: "discard", entry_ids: []))).to eq(Timekeeping::ReservationClient::Prepared.new(entries: []))
      expect(prepare(intent(kind: "destroy", entry_ids: [], invoice_id: 11))).to eq(Timekeeping::ReservationClient::Prepared.new(entries: []))
    end

    it "answers a replay of the same operation with the same Prepared" do
      prepared = intent

      expect(prepare(prepared)).to eq(prepare(prepared))
      expect(reservations.size).to eq(1)
    end

    it "never writes timesheet_entries" do
      projected = unbilled_entry(tenant_a)

      expect { prepare(intent) }.not_to change { TimesheetEntry.order(:id).pluck(:id, :locked, :updated_at) }
      expect(projected.reload.locked).to be(false)
    end
  end

  describe "a stored terminal receipt" do
    it "answers the client's Receipt, with the contract's string status (§9.2 step 3)" do
      committed, aborted = intent, intent(invoice_id: 11, entry_ids: [held_entry(offset: 1).id])
      prepare(committed)
      prepare(aborted)
      local.commit(invoice_id: committed.invoice_id, operation_id: committed.operation_id)
      local.abort(invoice_id: aborted.invoice_id, operation_id: aborted.operation_id)

      expect([prepare(committed), prepare(aborted)]).to eq([
        Timekeeping::ReservationClient::Receipt.new(status: "committed"),
        Timekeeping::ReservationClient::Receipt.new(status: "aborted")
      ])
    end
  end

  describe "the invoice's earlier operation (§5.3)" do
    let(:earlier) { intent }

    before { prepare(earlier) }

    it "resolves it with the outcome `resolves` carries, in the intent's string keys, then prepares" do
      later = intent

      answer = prepare(later, resolves: { "operation_id" => earlier.operation_id, "outcome" => "committed" })

      expect(answer).to be_a(Timekeeping::ReservationClient::Prepared)
      expect([receipt_of(earlier), receipt_of(later)]).to eq(%w[committed prepared])
      expect(reservations).to eq([[entry.id, 10, "committed", "active", true]])
    end

    it "is refused as operation-unresolved, retryable, when `resolves` does not carry it, and nothing changes" do
      before = local_state

      expect { prepare(intent) }.to raise_error(problem("operation-unresolved", status: 409, retryable: true))
      expect(local_state).to eq(before)
    end

    it "keeps the resolved outcome when the prepare itself is refused" do
      taken = held_entry(offset: 1)
      prepare(intent(invoice_id: 11, entry_ids: [taken.id]))

      expect {
        prepare(intent(entry_ids: [entry.id, taken.id]), resolves: { "operation_id" => earlier.operation_id, "outcome" => "aborted" })
      }.to raise_error(problem("reservation-refused", status: 409, retryable: false))
      expect(receipt_of(earlier)).to eq("aborted")
      expect(reservations).to eq([[taken.id, 11, "provisional", "active", true]])
    end
  end

  describe "a refused prepare" do
    it "raises reservation-refused with each refused entry and why, and reserves nothing (F1, L8)" do
      prepare(intent(invoice_id: 11))
      foreign = held_entry(offset: 1, tenant: tenant_b)
      missing = first_id + 99
      before = local_state

      expect { prepare(intent(entry_ids: [entry.id, foreign.id, missing])) }
        .to raise_error(problem("reservation-refused", status: 409, retryable: false)) { |error|
          expect(error.refused).to eq([
            TimekeepingReservations::Refusal.new(entry_id: entry.id, reason: :on_other_invoice),
            TimekeepingReservations::Refusal.new(entry_id: foreign.id, reason: :wrong_company),
            TimekeepingReservations::Refusal.new(entry_id: missing, reason: :not_found)
          ])
        }
      expect(local_state).to eq(before)
    end

    it "refuses an entry only the projection holds: the prepared application is authoritative (§5.3)" do
      projected = unbilled_entry(tenant_a)

      expect { prepare(intent(entry_ids: [projected.id])) }.to raise_error(problem("reservation-refused", status: 409, retryable: false)) { |error|
        expect(error.refused).to eq([TimekeepingReservations::Refusal.new(entry_id: projected.id, reason: :not_found)])
      }
    end

    it "raises idempotency-conflict for a replay with another body, and nothing changes" do
      prepared = intent
      prepare(prepared)
      before = local_state

      expect { prepare(prepared, invoice_state: :non_draft) }.to raise_error(problem("idempotency-conflict", status: 409, retryable: false))
      expect(local_state).to eq(before)
    end
  end

  describe "admission (§10.1)" do
    it "refuses an intent admitted under another generation as stale-generation, and writes nothing" do
      before = local_state

      expect { prepare(intent(generation: generation - 1)) }.to raise_error(problem("stale-generation", status: 409, retryable: false))
      expect { prepare(intent(generation: generation + 1)) }.to raise_error(problem("stale-generation", status: 409, retryable: false))
      expect(local_state).to eq(before)
    end

    it "refuses as stale-generation once this application no longer owns the entries" do
      set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("re-cut over to Timekeeping"))

      expect { prepare(intent(generation: 3)) }.to raise_error(problem("stale-generation", status: 409, retryable: false))
      expect(reservations).to eq([])
    end

    it "refuses as ownership-moving, retryable, while a handoff has admission closed at the intent's generation" do
      set_timekeeping_ownership!(generation:, owner: "monolith", state: "closed")

      expect { prepare(intent) }.to raise_error(problem("ownership-moving", status: 503, retryable: true))
      expect(reservations).to eq([])
    end

    it "holds the ownership row FOR SHARE before it touches a reservation" do
      prepared = intent
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
      prepare(prepared)
      ActiveSupport::Notifications.unsubscribe(subscriber)

      admission = statements.index { |sql| sql.include?("timekeeping_ownerships") && sql.include?("FOR SHARE") }
      first_reservation = statements.index { |sql| sql.include?("timekeeping_reservation") }
      expect(admission).not_to be_nil
      expect(admission).to be < first_reservation
    end
  end

  describe "commit and abort, the worker's delivery (§9.2 step 4)" do
    let(:prepared) { intent }

    before { prepare(prepared) }

    it "commits the prepared operation and answers the client's Receipt, with the contract's string status" do
      answer = client.commit(prepared)

      expect(answer).to eq(Timekeeping::ReservationClient::Receipt.new(status: "committed"))
      expect([reservations, receipt_of(prepared)]).to eq([[[entry.id, 10, "committed", "active", true]], "committed"])
      expect(entry.reload.outbox_snapshots.order(:version).last.snapshot.dig("data", "locked")).to be(true)
    end

    it "aborts the prepared operation, which drops its provisional reservation and the derived lock" do
      answer = client.abort(prepared)

      expect(answer).to eq(Timekeeping::ReservationClient::Receipt.new(status: "aborted"))
      expect([reservations, receipt_of(prepared)]).to eq([[], "aborted"])
      expect(entry.reload.outbox_snapshots.order(:version).last.snapshot.dig("data", "locked")).to be(false)
    end

    it "answers a resend with the stored receipt and changes nothing (§9.3 lost response on commit)" do
      client.commit(prepared)
      before = local_state

      expect(client.commit(prepared)).to eq(Timekeeping::ReservationClient::Receipt.new(status: "committed"))
      expect(local_state).to eq(before)
    end

    it "answers the stored receipt, not the delivery's, when the operation is already resolved the other way" do
      client.abort(prepared)

      expect(client.commit(prepared)).to eq(Timekeeping::ReservationClient::Receipt.new(status: "aborted"))
      expect(reservations).to eq([])
    end

    it "aborts an operation never prepared here as a no-op that still leaves an aborted receipt (§9.3)" do
      unprepared = intent(invoice_id: 11)
      before = reservations

      expect(client.abort(unprepared)).to eq(Timekeeping::ReservationClient::Receipt.new(status: "aborted"))
      expect([reservations, receipt_of(unprepared)]).to eq([before, "aborted"])
    end

    it "refuses a commit of an operation never prepared here as not-found, and records nothing" do
      unprepared = intent(invoice_id: 11)
      before = local_state

      expect { client.commit(unprepared) }.to raise_error(problem("not-found", status: 404, retryable: false))
      expect(local_state).to eq(before)
    end

    it "refuses a delivery under another generation as stale-generation, and resolves nothing" do
      stale = Timekeeping::InvoiceOperation.new(**prepared.attributes.symbolize_keys.slice(:operation_id, :invoice_id, :company_id, :kind, :entry_ids), generation: generation - 1)
      before = local_state

      expect { client.commit(stale) }.to raise_error(problem("stale-generation", status: 409, retryable: false))
      expect { client.abort(stale) }.to raise_error(problem("stale-generation", status: 409, retryable: false))
      expect(local_state).to eq(before)
    end

    it "refuses a delivery once this application no longer owns the entries, as stale-generation" do
      set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("re-cut over to Timekeeping"))

      expect { client.commit(prepared) }.to raise_error(problem("stale-generation", status: 409, retryable: false))
      expect(receipt_of(prepared)).to eq("prepared")
    end

    it "refuses a delivery as ownership-moving, retryable, while a handoff has admission closed at its generation" do
      set_timekeeping_ownership!(generation:, owner: "monolith", state: "closed")

      expect { client.abort(prepared) }.to raise_error(problem("ownership-moving", status: 503, retryable: true))
      expect(receipt_of(prepared)).to eq("prepared")
    end

    it "holds the ownership row FOR SHARE before it touches a reservation" do
      statements = []
      subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") { |*, payload| statements << payload[:sql] }
      client.commit(prepared)
      ActiveSupport::Notifications.unsubscribe(subscriber)

      admission = statements.index { |sql| sql.include?("timekeeping_ownerships") && sql.include?("FOR SHARE") }
      first_reservation = statements.index { |sql| sql.include?("timekeeping_reservation") }
      expect(admission).not_to be_nil
      expect(admission).to be < first_reservation
    end
  end

  describe ".problem" do
    it "builds every problem it raises from a body the contract's problem allows" do
      bodies = []
      allow(Timekeeping::ReservationClient::Problem).to receive(:new).and_wrap_original do |original, body|
        bodies << body
        original.call(body)
      end

      first = intent(invoice_id: 11)
      prepare(first)
      expect { prepare(intent(entry_ids: [entry.id])) }.to raise_error(Timekeeping::ReservationClient::Problem)
      expect { prepare(intent(invoice_id: 11)) }.to raise_error(Timekeeping::ReservationClient::Problem)
      expect { prepare(first, invoice_state: :non_draft) }.to raise_error(Timekeeping::ReservationClient::Problem)
      expect { prepare(intent(generation: 9)) }.to raise_error(Timekeeping::ReservationClient::Problem)
      expect { client.commit(intent(invoice_id: 12)) }.to raise_error(Timekeeping::ReservationClient::Problem)
      set_timekeeping_ownership!(generation:, owner: "monolith", state: "closed")
      expect { prepare(intent) }.to raise_error(Timekeeping::ReservationClient::Problem)

      expect(bodies.map { |body| body.fetch("type").split("/").last })
        .to eq(%w[reservation-refused operation-unresolved idempotency-conflict stale-generation not-found ownership-moving])
      bodies.each { |body| expect(Timekeeping::Contracts.errors(:reservation_api, problem_pointer, body)).to eq([]) }
    end
  end
end
