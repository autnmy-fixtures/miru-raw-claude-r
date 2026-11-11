# frozen_string_literal: true

require "rails_helper"

# Invoice candidate selection through the owner of the entries
# (docs/architecture/timekeeping-soa.md §3.3 rule 1, §5.2 candidates), through
# the real endpoint. Under `timekeeping` the suggestions are Timekeeping's
# candidates, never the projection, which may lag: an entry the relay has not
# projected yet is suggested and invoiced at once (§12.4 and §13 item 5,
# "relay paused"), and an entry an invoice holds is not suggested, by the
# owner's reservations. Under `legacy` nothing changes: no call, today's query
# (pinned by spec/requests/api/v1/invoices/line_items/index_spec.rb).
RSpec.describe "Timekeeping invoice candidate selection", type: :request do
  include_context "with two Timekeeping tenants"
  include TimekeepingContracts::ReservationDriver

  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: 1).install! }
  let(:admin) { tenant_a.admin }
  let(:member) { tenant_a.employee }
  let(:rate) { tenant_a.project.project_members.find_by!(user: member).hourly_rate }

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
  def owned_entry(tenant, **attributes)
    unbilled_entry(tenant, **attributes).tap do |entry|
      fake.seed_entry(
        company_id: tenant.company.id, id: entry.id, project_id: entry.project_id, user_id: entry.user_id,
        duration: entry.duration, work_date: entry.work_date.iso8601, note: entry.note
      )
    end
  end

  # An entry Timekeeping owns that the relay has not projected yet: no
  # timesheet_entries row holds it (§12.4 "relay paused").
  def unprojected_entry(tenant, work_date: Date.current, note: "Fresh work")
    id = TimesheetEntry.maximum(:id).to_i + 1_000 + (@unprojected = @unprojected.to_i + 1)
    fake.seed_entry(
      company_id: tenant.company.id, id:, project_id: tenant.project.id, user_id: tenant.employee.id,
      duration: 90.7, work_date: work_date.iso8601, note:
    )
  end

  def suggestions(**params)
    send_request :get, api_v1_line_items_invoices_path(client_id: tenant_a.client.id), params:, headers: auth_headers(admin)
    expect(response).to have_http_status(:ok)
    json_response
  end

  def suggested_ids(**params)
    suggestions(**params)["new_line_item_entries"].map { |line| line["timesheet_entry_id"] }
  end

  def candidate_calls = fake.calls.select { |call| call.operation == :candidates }

  def cut_over!
    set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("cut over to Timekeeping"))
  end

  describe "under the timekeeping owner" do
    before { cut_over! }

    it "suggests an entry the projection does not hold yet, as today's suggestion of a projected one" do
      fresh = unprojected_entry(tenant_a, note: "Fresh work")
      expect(TimesheetEntry.where(id: fresh["id"])).to be_empty

      body = suggestions

      expect(body["new_line_item_entries"]).to eq([{
        "selection_id" => "timesheet-entry-#{fresh['id']}", "timesheet_entry_id" => fresh["id"],
        "linked_timesheet_entry_ids" => [], "user_id" => member.id, "project_id" => tenant_a.project.id,
        "project_name" => tenant_a.project.name, "first_name" => member.first_name, "last_name" => member.last_name,
        "name" => nil, "description" => "Fresh work", "date" => fresh["work_date"], "date_range" => nil,
        "quantity" => 90.7, "rate" => JSON.parse(rate.to_json), "entry_count" => nil
      }])
      expect(body["total_new_line_items"]).to eq(1)
      expect(body["filter_options"]["team_members"]).to eq([{ "label" => member.full_name, "value" => member.id }])
      expect(candidate_calls.sole.input).to eq("client_id" => tenant_a.client.id.to_s, "project_ids" => [tenant_a.project.id.to_s])
    end

    it "groups projected and unprojected candidates by project, member and rate" do
      projected = owned_entry(tenant_a, duration: 60)
      fresh = unprojected_entry(tenant_a)

      group = suggestions(group_by_project: true)["new_line_item_entries"].sole

      expect(group).to include(
        "timesheet_entry_id" => nil, "project_id" => tenant_a.project.id, "entry_count" => 2,
        "description" => "#{member.full_name} - 2 entries", "quantity" => 150.7
      )
      expect(group["linked_timesheet_entry_ids"]).to contain_exactly(projected.id, fresh["id"])
    end

    it "invoices a new entry at once, and stops suggesting it once an invoice holds it (§13 item 5)" do
      fresh = unprojected_entry(tenant_a)
      line = suggestions["new_line_item_entries"].sole

      send_request :post, api_v1_invoices_path, params: { invoice: {
        client_id: tenant_a.client.id, invoice_number: "TK-#{SecureRandom.hex(3)}", status: "draft",
        issue_date: Date.current.iso8601, due_date: Date.current.iso8601, currency: tenant_a.company.base_currency,
        invoice_line_items_attributes: [{
          name: line["project_name"], date: line["date"], timesheet_entry_id: line["timesheet_entry_id"],
          quantity: line["quantity"], rate: line["rate"]
        }]
      } }, headers: auth_headers(admin)

      expect(response).to have_http_status(:ok)
      expect(Invoice.find(json_response["id"]).invoice_line_items.sole.timesheet_entry_id).to eq(fresh["id"])
      expect(fake.holding(fresh["id"])).to be_present
      expect(suggested_ids).to eq([])
    end

    it "does not suggest an entry an invoice holds by its reservation, which no local invoice line shows" do
      held = owned_entry(tenant_a)
      free = owned_entry(tenant_a)
      prepare_in_timekeeping(Timekeeping::InvoiceOperation.new(
        operation_id: SecureRandom.uuid, invoice_id: 9_001, company_id: tenant_a.company.id, kind: "save",
        entry_ids: [held.id], generation: 1
      ))

      expect(suggested_ids).to eq([free.id])
      expect(candidate_calls.sole.input).not_to have_key("exclude_ids")
    end

    it "carries the selected entries and today's filters to the owner (§5.2)" do
      selected = owned_entry(tenant_a, work_date: 1.week.ago.to_date)
      match = owned_entry(tenant_a, work_date: 1.week.ago.to_date, note: "Sprint review")
      owned_entry(tenant_a, work_date: 3.weeks.ago.to_date, note: "Sprint review")
      from, to = 1.week.ago.beginning_of_week.to_date, 1.week.ago.end_of_week.to_date

      ids = suggested_ids(
        selected_entries: [selected.id], team_member: [member.id], search_term: "Sprint",
        date_range: "custom", from: from.iso8601, to: to.iso8601
      )

      expect(ids).to eq([match.id])
      expect(candidate_calls.sole.input).to eq(
        "client_id" => tenant_a.client.id.to_s, "project_ids" => [tenant_a.project.id.to_s],
        "user_ids" => [member.id.to_s], "exclude_ids" => [selected.id.to_s],
        "from" => from.iso8601, "to" => to.iso8601, "search_term" => "Sprint"
      )
    end

    it "suggests only the caller's tenant's entries (§6.3)" do
      own = unprojected_entry(tenant_a)
      unprojected_entry(tenant_b)
      foreign = fake.seed_entry(
        company_id: tenant_b.company.id, project_id: tenant_a.project.id, user_id: member.id,
        duration: 30.0, work_date: Date.current.iso8601
      )

      expect(suggested_ids).to eq([own["id"]])
      expect(suggested_ids).not_to include(foreign["id"])
      expect(candidate_calls.map { |call| call.claims["company_id"] }.uniq).to eq([tenant_a.company.id])
    end

    it "answers a retryable 503 and reads nothing locally when Timekeeping is down" do
      fake.lose_next_response(:candidates)

      send_request :get, api_v1_line_items_invoices_path(client_id: tenant_a.client.id), headers: auth_headers(admin)

      expect(response).to have_http_status(:service_unavailable)
      expect(json_response["errors"]).to eq(I18n.t("timesheet_entry.unavailable"))
    end
  end

  it "reads today's table under legacy, with no call" do
    entry = unbilled_entry(tenant_a)

    expect(suggested_ids).to eq([entry.id])
    expect(fake.calls).to be_empty
  end

  it "refuses under the monolith owner, which has no entry store yet" do
    set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rolled back to the prepared application"))

    expect {
      send_request :get, api_v1_line_items_invoices_path(client_id: tenant_a.client.id), headers: auth_headers(admin)
    }.to raise_error(Timekeeping::Gateway::OwnerUnavailable, /candidate selection: owner monolith/)
  end
end
