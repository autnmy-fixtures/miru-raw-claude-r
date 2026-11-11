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
