# frozen_string_literal: true

require "rails_helper"

# The invoice writes of docs/architecture/timekeeping-soa.md §3.1 (W7) wired
# through the invoice reservation boundary, through the real endpoints:
# create and update are a save, a single delete a discard, a bulk delete a
# destroy (§1.4). Under `timekeeping` the owner holds the reservations
# (§7.2) and today's lock callbacks stand down, so no invoice write touches
# timesheet_entries, the projection. Under `legacy` nothing changes: no
# intent, no call, today's callbacks (pinned by the characterization specs).
RSpec.describe "Timekeeping invoice writes through the reservation boundary", type: :request do
  include_context "with two Timekeeping tenants"
  include TimekeepingSingleWriterGuard

  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: 1).install! }
  let(:admin) { tenant_a.admin }
  let(:entry_x) { owned_entry(tenant_a) }
  let(:entry_y) { owned_entry(tenant_a) }
  let(:worker) { Timekeeping::InvoiceOperationWorker.new }

  around do |example|
    config = Rails.configuration.x.timekeeping
    url, key = config.url, config.token_key
    config.url, config.token_key = TimekeepingContracts::FakeTimekeeping::URL, TimekeepingContracts::TEST_TOKEN_KEY
    example.run
  ensure
    config.url, config.token_key = url, key
  end

  before { sign_in admin }

  after { expect(fake.violations).to be_empty }

  # An entry in the projection and in Timekeeping under the same id, as the
  # first cutover leaves it (§10.3).
  def owned_entry(tenant)
    unbilled_entry(tenant).tap do |entry|
      fake.seed_entry(
        company_id: tenant.company.id, id: entry.id, project_id: entry.project_id, user_id: entry.user_id,
        duration: entry.duration, work_date: entry.work_date.iso8601
      )
    end
  end

  # An entry Timekeeping owns that the relay has not projected yet: no
  # timesheet_entries row holds it (§3.3, §12.4 "relay paused").
  UnprojectedEntry = Data.define(:id, :work_date)

  def unprojected_entry(tenant)
    id = TimesheetEntry.maximum(:id).to_i + 1_000 + (@unprojected = @unprojected.to_i + 1)
    fake.seed_entry(
      company_id: tenant.company.id, id:, project_id: tenant.project.id, user_id: tenant.employee.id,
      duration: 90.7, work_date: Date.current.iso8601
    )
    UnprojectedEntry.new(id:, work_date: Date.current)
  end

  def cut_over!
    set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping"))
  end

  def invoice_params(status: "draft", lines: [])
    {
      client_id: tenant_a.client.id, invoice_number: "TK-#{SecureRandom.hex(3)}",
      issue_date: Date.current.iso8601, due_date: Date.current.iso8601, status:,
      currency: tenant_a.company.base_currency, invoice_line_items_attributes: lines
    }
  end

  def direct(entry)
    { name: "Direct", date: entry.work_date.iso8601, timesheet_entry_id: entry.id, quantity: 60, rate: 100 }
  end

  def grouped(*entries)
    { name: "Grouped", date: Date.current.iso8601, linked_timesheet_entry_ids: entries.map(&:id), quantity: 120, rate: 100 }
  end

  def create_invoice(**params)
    send_request :post, api_v1_invoices_path, params: { invoice: invoice_params(**params) }, headers: auth_headers(admin)
  end

  def update_invoice(invoice, **params)
    send_request :patch, api_v1_invoice_path(invoice), params: { invoice: params }, headers: auth_headers(admin)
  end

  def prepare_calls = fake.calls.select { |call| call.operation == :prepare }

  def intents = Timekeeping::InvoiceOperation.order(:id).to_a

  def locks = TimesheetEntry.order(:id).pluck(:id, :locked)

  def invoice_with_lines
    create_invoice(lines: [direct(entry_x), grouped(entry_x, entry_y)])
    expect(response).to have_http_status(:ok)
    worker.run
    Invoice.find(json_response["id"])
  end

  describe "under the timekeeping owner" do
    before do
      entry_x
      entry_y
      cut_over!
    end

    it "creates a draft after the owner prepared its direct and grouped entries, and writes no entry (§9.2)" do
      before = locks

      create_invoice(lines: [direct(entry_x), grouped(entry_x, entry_y)])

      expect(response).to have_http_status(:ok)
      invoice = Invoice.find(json_response["id"])
      intent = intents.sole
      aggregate_failures do
        expect(intent).to have_attributes(invoice_id: invoice.id, company_id: tenant_a.company.id, kind: "save", state: "succeeded")
        expect(intent.entry_ids).to contain_exactly(entry_x.id, entry_y.id)
        expect(prepare_calls.sole.params).to eq("invoice_id" => invoice.id.to_s, "operation_id" => intent.operation_id)
        expect(prepare_calls.sole.input).to include("kind" => "save", "invoice_state" => "draft", "entry_ids" => [entry_x.id, entry_y.id].sort)
        expect(invoice.invoice_line_items.count).to eq(2)
        expect(locks).to eq(before)
      end

      worker.run
      expect([entry_x, entry_y].map { |entry| fake.holding(entry.id).state }).to eq([:committed, :committed])
    end

    it "writes no timesheet_entries row from any invoice write: the projection has one writer (§3.2, §12.2)" do
      writes = timesheet_entry_writes do
        create_invoice(lines: [direct(entry_x), grouped(entry_x, entry_y)])
        invoice = Invoice.find(json_response["id"])
        worker.run
        update_invoice(invoice, invoice_line_items_attributes: [{ id: invoice.invoice_line_items.find_by!(timesheet_entry_id: nil).id, _destroy: "1" }])
        worker.run
        send_request :delete, api_v1_invoice_path(invoice), headers: auth_headers(admin)
        worker.run
        send_request :post, api_v1_invoices_bulk_deletion_index_path, params: { invoices_ids: [invoice.id] }, headers: auth_headers(admin)
      end

      expect(response).to have_http_status(:no_content)
      expect(intents.map { |intent| [intent.kind, intent.state] }).to eq([%w[save succeeded], %w[save succeeded], %w[discard succeeded], %w[destroy succeeded]])
      expect(writes).to eq([])
    end

    describe "an entry the projection does not hold yet (§3.3 rule 1, L8)" do
      let(:fresh) { unprojected_entry(tenant_a) }
      let(:fresher) { unprojected_entry(tenant_a) }

      def lines_of(invoice)
        invoice.invoice_line_items.order(:id).map { |line| [line.timesheet_entry_id, line.linked_timesheet_entry_ids.sort] }
      end

      it "is invoiced at once, directly and through a grouped line, on the owner's prepare answer" do
        expect(TimesheetEntry.where(id: [fresh.id, fresher.id])).to be_empty

        create_invoice(lines: [direct(fresh), grouped(fresh, fresher, entry_x)])

        expect(response).to have_http_status(:ok)
        invoice = Invoice.find(json_response["id"])
        aggregate_failures do
          expect(lines_of(invoice)).to eq([[fresh.id, []], [nil, [entry_x.id, fresh.id, fresher.id].sort]])
          expect(json_response["invoiceLineItems"].map { |line| line["linkedTimesheetEntryIds"].sort })
            .to eq([[], [entry_x.id, fresh.id, fresher.id].sort])
          expect(intents.sole).to have_attributes(state: "succeeded", entry_ids: [entry_x.id, fresh.id, fresher.id].sort)
          expect(TimesheetEntry.where(id: [fresh.id, fresher.id])).to be_empty
        end

        worker.run
        expect([fresh, fresher, entry_x].map { |entry| fake.holding(entry.id).state }).to eq([:committed, :committed, :committed])
      end

      it "is linked to and unlinked from a saved grouped line, keeping the links the line already held" do
        create_invoice(lines: [grouped(entry_x, fresh)])
        invoice = Invoice.find(json_response["id"])
        worker.run
        line = invoice.invoice_line_items.sole
        kept_link = line.invoice_line_item_time_entries.find_by!(timesheet_entry_id: fresh.id)

        update_invoice(invoice, invoice_line_items_attributes: [{ id: line.id, linked_timesheet_entry_ids: [fresh.id, fresher.id] }])

        expect(response).to have_http_status(:ok)
        expect(lines_of(invoice)).to eq([[nil, [fresh.id, fresher.id].sort]])
        expect(line.invoice_line_item_time_entries.find_by!(timesheet_entry_id: fresh.id).id).to eq(kept_link.id)
        expect(intents.last).to have_attributes(state: "succeeded", entry_ids: [fresh.id, fresher.id].sort)

        worker.run
        expect(fake.holding(entry_x.id)).to be_nil
        expect([fresh, fresher].map { |entry| fake.holding(entry.id).state }).to eq([:committed, :committed])
      end

      it "is refused when Timekeeping does not hold it either, and nothing is written" do
        missing = UnprojectedEntry.new(id: TimesheetEntry.maximum(:id).to_i + 5_000, work_date: Date.current)

        expect { create_invoice(lines: [grouped(entry_x, missing)]) }.not_to change { [Invoice.count, InvoiceLineItemTimeEntry.count] }

        expect(response).to have_http_status(:unprocessable_entity)
        expect(json_response["errors"]).to eq(I18n.t("invoices.reservation.refused.not_found", entry_id: missing.id))
        expect(intents.sole.state).to eq("failed")
      end
    end

    it "prepares a save of a non-draft as non-draft" do
      create_invoice(status: "sent", lines: [direct(entry_x)])

      expect(response).to have_http_status(:ok)
      expect(prepare_calls.sole.input).to include("invoice_state" => "non_draft", "entry_ids" => [entry_x.id])
    end

    it "keeps an entry another line references when a grouped line is removed, and releases the rest (F3)" do
      invoice = invoice_with_lines
      grouped_line = invoice.invoice_line_items.find_by!(timesheet_entry_id: nil)

      update_invoice(invoice, invoice_line_items_attributes: [{ id: grouped_line.id, _destroy: "1" }])

      expect(response).to have_http_status(:ok)
      expect(prepare_calls.last.input).to include("kind" => "save", "invoice_state" => "draft", "entry_ids" => [entry_x.id])
      expect(intents.last).to have_attributes(state: "succeeded", entry_ids: [entry_x.id])

      worker.run
      expect(fake.holding(entry_x.id).state).to eq(:committed)
      expect(fake.holding(entry_y.id)).to be_nil
    end

    it "refuses an entry already on another invoice before the invoice is written (F1)" do
      invoice_with_lines

      expect { create_invoice(lines: [direct(entry_y)]) }.not_to change(Invoice, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response["errors"]).to eq(I18n.t("invoices.reservation.refused.on_other_invoice", entry_id: entry_y.id))
      expect(intents.last.state).to eq("failed")
    end

    it "refuses another tenant's entry (L8, §6.3)" do
      other = owned_entry(tenant_b)

      expect { create_invoice(lines: [direct(other)]) }.not_to change(Invoice, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response["errors"]).to eq(I18n.t("invoices.reservation.refused.wrong_company", entry_id: other.id))
      expect(fake.holding(other.id)).to be_nil
    end

    it "fails with a retryable 503 and writes nothing when Timekeeping is down at prepare (§9.3)" do
      WebMock::API.stub_request(:post, %r{/prepare\z}).to_raise(Errno::ECONNREFUSED)

      expect { create_invoice(lines: [direct(entry_x)]) }.not_to change(Invoice, :count)

      expect(response).to have_http_status(:service_unavailable)
      expect(json_response["errors"]).to eq(I18n.t("invoices.reservation.unavailable"))
      expect(intents.sole.state).to eq("failed")
    end

    it "answers a retryable 409 while another operation of the invoice is pending (§9.1)" do
      invoice = invoice_with_lines
      Timekeeping::InvoiceOperation.open!(invoice_id: invoice.id, company_id: invoice.company_id, kind: :save)

      update_invoice(invoice, reference: "busy")

      expect(response).to have_http_status(:conflict)
      expect(json_response["errors"]).to eq(I18n.t("invoices.reservation.busy"))
      expect(invoice.reload.reference).not_to eq("busy")
    end

    it "releases a discarded draft's entries, and leaves the projection to the consumer (F2)" do
      invoice = invoice_with_lines
      before = locks

      send_request :delete, api_v1_invoice_path(invoice), headers: auth_headers(admin)

      expect(response).to have_http_status(:no_content)
      expect(invoice.reload).to be_discarded
      expect(prepare_calls.last.input).to include("kind" => "discard", "invoice_state" => "draft", "entry_ids" => [])
      expect(locks).to eq(before)

      worker.run
      expect([entry_x, entry_y].map { |entry| fake.holding(entry.id) }).to eq([nil, nil])
    end

    it "destroys through the boundary on a bulk delete" do
      invoice = invoice_with_lines

      send_request :post, api_v1_invoices_bulk_deletion_index_path, params: { invoices_ids: [invoice.id] }, headers: auth_headers(admin)

      expect(response).to have_http_status(:no_content)
      expect(Invoice.exists?(invoice.id)).to be(false)
      expect(prepare_calls.last.input).to include("kind" => "destroy", "invoice_state" => "draft", "entry_ids" => [])
      expect(intents.last.state).to eq("succeeded")
    end

    it "keeps an invoice with payments and its reservations when a bulk delete refuses it" do
      invoice = invoice_with_lines
      create(:payment, invoice:)

      send_request :post, api_v1_invoices_bulk_deletion_index_path, params: { invoices_ids: [invoice.id] }, headers: auth_headers(admin)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response["undeletable_invoice_ids"]).to eq([invoice.id])
      expect(invoice.reload.invoice_line_items.count).to eq(2)
      expect(intents.last.state).to eq("failed")

      worker.run
      expect([entry_x, entry_y].map { |entry| fake.holding(entry.id).state }).to eq([:committed, :committed])
    end
  end

  # Under `monolith`, the prepared application after a rollback (§10.5), the
  # same endpoints prepare in-process against its own reservation table and
  # entries (Timekeeping::LocalReservationClient): no call reaches
  # Timekeeping, and no invoice write touches timesheet_entries. Commit and
  # abort are not delivered to it by the worker yet, so these examples
  # deliver them as the worker will.
  describe "under the monolith owner" do
    let(:first_id) { TimesheetEntry.maximum(:id).to_i + 1_000 }
    let(:local) { Timekeeping::LocalReservations.new(entries: Timekeeping::LocalEntries.new) }
    let(:held_x) { held_entry(tenant_a, offset: 0) }
    let(:held_y) { held_entry(tenant_a, offset: 1) }

    before do
      held_x
      held_y
      set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rolled back to the prepared application"))
    end

    after { expect(fake.calls).to be_empty }

    # An entry the prepared application holds that the projection does not
    # (§3.3 rule 1): its own table is authoritative under this owner.
    def held_entry(tenant, offset:)
      Timekeeping::Entry.create!(
        id: first_id + offset, company_id: tenant.company.id, project_id: tenant.project.id, user_id: tenant.employee.id,
        duration: 90.7, work_date: Date.current, bill_status: "unbilled"
      )
    end

    def local_reservations
      Timekeeping::Reservation.order(:entry_id).pluck(:entry_id, :invoice_id, :state, :disposition, :edit_lock)
    end

    # Commit or abort of every undelivered outcome, as the worker will
    # deliver it under this owner.
    def deliver_locally!
      Timekeeping::InvoiceOperation.undelivered.order(:id).each do |intent|
        local.public_send(intent.delivery, invoice_id: intent.invoice_id, operation_id: intent.operation_id)
        intent.mark_delivered!
      end
    end

    def local_invoice_with_lines
      create_invoice(lines: [direct(held_x), grouped(held_x, held_y)])
      expect(response).to have_http_status(:ok)
      deliver_locally!
      Invoice.find(json_response["id"])
    end

    it "creates a draft over the prepared application's entries, and writes no timesheet_entries row (§3.2, §12.2)" do
      expect(TimesheetEntry.where(id: [held_x.id, held_y.id])).to be_empty

      writes = timesheet_entry_writes { create_invoice(lines: [direct(held_x), grouped(held_x, held_y)]) }

      expect(response).to have_http_status(:ok)
      invoice = Invoice.find(json_response["id"])
      aggregate_failures do
        expect(writes).to eq([])
        expect(intents.sole).to have_attributes(invoice_id: invoice.id, kind: "save", state: "succeeded", generation: 2)
        expect(intents.sole.entry_ids).to eq([held_x.id, held_y.id])
        expect(invoice.invoice_line_items.order(:id).map { |line| [line.timesheet_entry_id, line.linked_timesheet_entry_ids.sort] })
          .to eq([[held_x.id, []], [nil, [held_x.id, held_y.id]]])
        expect(local_reservations).to eq([
          [held_x.id, invoice.id, "provisional", "active", true], [held_y.id, invoice.id, "provisional", "active", true]
        ])
        expect([held_x, held_y].map { |entry| entry.reload.outbox_snapshots.order(:version).last.snapshot.dig("data", "locked") }).to eq([true, true])
      end

      deliver_locally!
      expect(local_reservations.map { |row| row[2] }).to eq(%w[committed committed])
    end

    it "prepares a save of a non-draft as non-draft, with no edit lock (L1)" do
      create_invoice(status: "sent", lines: [direct(held_x)])

      expect(response).to have_http_status(:ok)
      expect(local_reservations).to eq([[held_x.id, json_response["id"], "provisional", "active", false]])
    end

    it "keeps an entry another line references when a grouped line is removed, and releases the rest (F3)" do
      invoice = local_invoice_with_lines
      grouped_line = invoice.invoice_line_items.find_by!(timesheet_entry_id: nil)

      update_invoice(invoice, invoice_line_items_attributes: [{ id: grouped_line.id, _destroy: "1" }])

      expect(response).to have_http_status(:ok)
      expect(intents.last).to have_attributes(state: "succeeded", entry_ids: [held_x.id])

      deliver_locally!
      expect(local_reservations).to eq([[held_x.id, invoice.id, "committed", "active", true]])
    end

    it "carries an undelivered outcome to the next save of the invoice, which applies it first (§5.3)" do
      create_invoice(lines: [direct(held_x)])
      invoice = Invoice.find(json_response["id"])

      update_invoice(invoice, invoice_line_items_attributes: [{ id: invoice.invoice_line_items.sole.id, _destroy: "1" }])

      expect(response).to have_http_status(:ok)
      expect(Timekeeping::ReservationOperation.order(:id).pluck(:operation_id, :state))
        .to eq([[intents.first.operation_id, "committed"], [intents.last.operation_id, "prepared"]])
      deliver_locally!
      expect(local_reservations).to eq([])
    end

    it "refuses an entry already on another invoice before the invoice is written (F1)" do
      local_invoice_with_lines

      expect { create_invoice(lines: [direct(held_y)]) }.not_to change(Invoice, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response["errors"]).to eq(I18n.t("invoices.reservation.refused.on_other_invoice", entry_id: held_y.id))
      expect(intents.last.state).to eq("failed")
    end

    it "refuses another tenant's entry (L8, §6.3)" do
      other = held_entry(tenant_b, offset: 2)

      expect { create_invoice(lines: [direct(other)]) }.not_to change(Invoice, :count)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response["errors"]).to eq(I18n.t("invoices.reservation.refused.wrong_company", entry_id: other.id))
      expect(local_reservations).to eq([])
    end

    it "refuses an entry only the projection holds: the prepared application is authoritative (§5.3)" do
      projected = unbilled_entry(tenant_a)

      expect { create_invoice(lines: [grouped(held_x, projected)]) }.not_to change { [Invoice.count, InvoiceLineItemTimeEntry.count] }

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json_response["errors"]).to eq(I18n.t("invoices.reservation.refused.not_found", entry_id: projected.id))
      expect(intents.sole.state).to eq("failed")
    end

    it "releases a discarded draft's entries (F2)" do
      invoice = local_invoice_with_lines

      send_request :delete, api_v1_invoice_path(invoice), headers: auth_headers(admin)

      expect(response).to have_http_status(:no_content)
      expect(invoice.reload).to be_discarded
      expect(intents.last).to have_attributes(kind: "discard", state: "succeeded")
      deliver_locally!
      expect(local_reservations).to eq([])
    end

    it "keeps a destroyed non-draft's entries as retained (§7.3, K7)" do
      create_invoice(status: "sent", lines: [direct(held_x)])
      invoice = Invoice.find(json_response["id"])
      deliver_locally!

      send_request :post, api_v1_invoices_bulk_deletion_index_path, params: { invoices_ids: [invoice.id] }, headers: auth_headers(admin)

      expect(response).to have_http_status(:no_content)
      expect(Invoice.exists?(invoice.id)).to be(false)
      expect(intents.last).to have_attributes(kind: "destroy", state: "succeeded")
      deliver_locally!
      expect(local_reservations).to eq([[held_x.id, invoice.id, "committed", "retained", false]])
    end
  end

  describe "under the legacy owner" do
    it "writes invoices as today, with no intent and no call" do
      create_invoice(lines: [direct(entry_x), grouped(entry_x, entry_y)])
      invoice = Invoice.find(json_response["id"])
      expect([entry_x, entry_y].map { |entry| entry.reload.locked }).to eq([true, true])

      grouped_line = invoice.invoice_line_items.find_by!(timesheet_entry_id: nil)
      update_invoice(invoice, invoice_line_items_attributes: [{ id: grouped_line.id, _destroy: "1" }])
      expect(response).to have_http_status(:ok)
      send_request :delete, api_v1_invoice_path(invoice), headers: auth_headers(admin)
      expect(response).to have_http_status(:no_content)

      expect(intents).to be_empty
      expect(fake.calls).to be_empty
    end
  end
end
