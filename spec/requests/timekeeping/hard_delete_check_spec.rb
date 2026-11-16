# frozen_string_literal: true

require "rails_helper"

# The hard-delete-of-a-non-draft part of the failure injection (Timekeeping::
# HardDeleteCheck; docs/architecture/timekeeping-soa.md §12.4, §9.3, §7.3,
# §13 item 6), run in process through the real controllers, invoice writes
# and invoice operation worker on two tenants. The whole proof runs under the
# prepared application after a rollback, whose own reservation table keeps
# the shared decision table's rules (edit locks, retained reservations,
# successors), so the check's every step is pinned against the real rule.
# Under Timekeeping its consumer-side fake (FakeTimekeeping) stands in, which
# keeps the protocol and none of the rules, so there the check must stop at
# the first edit lock it reads; the running Timekeeping is proved by
# bin/timekeeping-demo hard-delete. The worker runs after every request, as
# miru-jobs does.
RSpec.describe Timekeeping::HardDeleteCheck, type: :request do
  include TimekeepingCharacterization::Helpers

  let(:password) { "Password123!" }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let(:tenants) do
    [tenant_a, tenant_b].each_with_index.map do |tenant, index|
      tenant.company.update!(name: "Hard delete business #{index + 1}")
      { name: tenant.company.name, employee: tenant.employee.email, admin: tenant.admin.email }
    end
  end
  let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rolled back to the prepared application") }
  let(:log) { StringIO.new }
  let(:run_name) { "20261116T200000Z-0a1b" }
  # Called with each request and its answer, after the worker ran.
  let(:after_request) { ->(_request, _answer) { } }

  let(:transport) do
    lambda do |request|
      headers = request.each_capitalized.to_h.except("Host", "Content-Length", "Accept-Encoding", "User-Agent")
      # The client keeps no cookies; sign-in sets a session one, which would
      # otherwise sign every later request in as that user.
      reset!
      public_send(request.method.downcase, request.path, params: request.body, headers:)
      answer = [response.status, response.content_type.to_s, response.body]
      Timekeeping::InvoiceOperationWorker.new.run
      after_request.call(request, answer)
      answer
    end
  end

  def check(run: run_name)
    described_class.new(
      client: Timekeeping::PublicApi::Client.new(base_url: "http://www.example.com", transport:), password:, run:,
      logger: Logger.new(log), options: described_class::Options.new(wait: 2, tenants:)
    )
  end

  def invoice_of(tenant, letter)
    # A discarded invoice's number gains a prefix (Invoice#update_invoice_number).
    Invoice.with_discarded.where(company: tenant.company)
      .find_by("invoice_number LIKE ?", "%HDL-#{tenant.company.id}-#{run_name}-#{letter}")
  end

  def intents_of(invoice_id) = Timekeeping::InvoiceOperation.where(invoice_id:).order(:id).map { |intent| [intent.kind, intent.state] }

  before do
    tenants
    set_timekeeping_ownership!(ownership)
  end

  context "when the prepared application owns the entries, after a rollback" do
    before { advance_local_entry_ids! }

    def entry_of(tenant, letter)
      Timekeeping::Entry.find_by!(company_id: tenant.company.id, note: [
        "Hard delete #{run_name} #{letter}", "Hard delete #{run_name} #{letter} edited"
      ])
    end

    def reservations_of(entry) = Timekeeping::Reservation.where(entry_id: entry.id).pluck(:invoice_id, :state, :disposition, :edit_lock)

    context "when every step holds" do
      # The reservations each successful bulk delete left, as it answered.
      let(:retained) { [] }
      let(:after_request) do
        lambda do |request, answer|
          next unless request.path == described_class::BULK_DELETE && answer.first == 204

          retained << Timekeeping::Reservation.where(invoice_id: JSON.parse(request.body).fetch("invoices_ids"))
            .pluck(:entry_id, :invoice_id, :state, :disposition, :edit_lock)
        end
      end

      it "keeps a non-draft whose delete fails, and retains a deleted one's entry until a successor takes it over, on both tenants" do
        check.call

        [tenant_a, tenant_b].each do |tenant|
          x_invoice = invoice_of(tenant, "X")
          x = entry_of(tenant, "X")
          y = entry_of(tenant, "Y")
          successor = invoice_of(tenant, "S")
          aggregate_failures do
            # X: still on its sent invoice, with its line and payment, reserved
            # active with the edit lock; the refused delete failed and aborted.
            expect(x_invoice).to have_attributes(status: "sent", discarded_at: nil)
            expect(x_invoice.invoice_line_items.pluck(:timesheet_entry_id)).to eq([x.id])
            expect(x_invoice.payments.count).to eq(1)
            expect(intents_of(x_invoice.id)).to eq([%w[save succeeded], %w[save succeeded], %w[destroy failed]])
            expect(reservations_of(x)).to eq([[x_invoice.id, "committed", "active", true]])
            expect(x).to have_attributes(note: "Hard delete #{run_name} X", discarded_at: nil)

            # Y: its invoice destroyed, then taken over by the successor draft,
            # which was discarded, releasing it; then edited and discarded.
            expect(invoice_of(tenant, "Y")).to be_nil
            y_invoice_id = Timekeeping::InvoiceOperation.where(kind: "destroy", state: "succeeded", company_id: tenant.company.id).sole.invoice_id
            expect(intents_of(y_invoice_id)).to eq([%w[save succeeded], %w[save succeeded], %w[destroy succeeded]])
            expect(retained).to include([[y.id, y_invoice_id, "committed", "retained", true]])
            expect(successor).to be_discarded
            expect(intents_of(successor.id)).to eq([%w[save succeeded], %w[discard succeeded]])
            expect(reservations_of(y)).to be_empty
            expect(y).to have_attributes(note: "Hard delete #{run_name} Y edited", discarded_at: be_present)
          end
        end
        expect(Timekeeping::InvoiceOperation.undelivered).to be_empty
        expect(log.string).to include(
          "was refused with 422, as it has a recorded payment",
          "keeps its edit lock and is offered again (retained)",
          "took entry",
          "so the successor's commit had removed the retained reservation",
          "on 2 businesses, under owner monolith at generation 2"
        )
      end
    end

    context "when the owner releases a deleted non-draft's entry instead of retaining it" do
      let(:after_request) do
        lambda do |request, answer|
          next unless request.path == described_class::BULK_DELETE && answer.first == 204

          Timekeeping::Reservation.where(disposition: "retained").delete_all
        end
      end

      it "fails, as the entry lost its edit lock" do
        expect { check.call }.to raise_error(described_class::Failed, /after the delete of invoice \d+, entry \d+ is not locked on its owner/)
      end
    end

    context "when a failed delete releases the entry" do
      let(:after_request) do
        lambda do |request, answer|
          next unless request.path == described_class::BULK_DELETE && answer.first == 422

          Timekeeping::Reservation.delete_all
        end
      end

      it "fails, as the prior state did not hold" do
        expect { check.call }.to raise_error(described_class::Failed, /the failed delete of invoice \d+ changed entry \d+ on its owner/)
      end
    end

    context "when the delete of an invoice with a payment is not refused" do
      # As if the restriction were gone: the payments go with the invoice.
      before do
        allow_any_instance_of(Invoice).to receive(:destroy!).and_wrap_original do |original|
          Payment.where(invoice_id: original.receiver.id).delete_all
          original.call
        end
      end

      it "fails, naming what the bulk delete answered" do
        expect { check.call }.to raise_error(described_class::Failed, /which has a recorded payment, answered 204/)
      end
    end
  end

  context "when Timekeeping owns the entries" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping") }
    let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: ownership[:generation]).install! }

    around do |example|
      config = Rails.configuration.x.timekeeping
      url, key = config.url, config.token_key
      config.url, config.token_key = TimekeepingContracts::FakeTimekeeping::URL, TimekeepingContracts::TEST_TOKEN_KEY
      example.run
    ensure
      config.url, config.token_key = url, key
    end

    after { expect(fake.violations).to be_empty }

    it "reads the edit lock from Timekeeping, and stops at the first one the fake, which keeps none, does not hold" do
      expect { check.call }.to raise_error(described_class::Failed, /after marking invoice \d+ sent, entry \d+ is not locked on its owner/)

      x_invoice = invoice_of(tenant_a, "X")
      expect(x_invoice).to have_attributes(status: "sent")
      expect(fake.holding(x_invoice.invoice_line_items.sole.timesheet_entry_id)).to have_attributes(invoice_id: x_invoice.id, state: :committed)
      expect(fake.calls.map(&:operation)).to include(:show_entry)
    end
  end

  context "when the legacy owner holds the entries" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff aborted") }

    it "refuses before anything is written" do
      expect { check.call }.to raise_error(described_class::Failed, /Timekeeping or the prepared application owns the entries .*owner legacy/)
      expect(Invoice.where("invoice_number LIKE ?", "HDL-%")).to be_empty
    end
  end

  context "when admission is not open" do
    let(:ownership) { TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rollback, frozen") }

    it "refuses, as a handoff is moving the entries" do
      expect { check.call }.to raise_error(described_class::Failed, /admission open/)
      expect(Invoice.where("invoice_number LIKE ?", "HDL-%")).to be_empty
    end
  end

  it "refuses a run name that could not be part of an invoice number" do
    expect { check(run: "a b;c") }.to raise_error(described_class::Failed, /a run name is letters, digits and dashes/)
  end
end
