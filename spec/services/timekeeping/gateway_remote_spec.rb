# frozen_string_literal: true

require "rails_helper"

# The gateway's `timekeeping` owner (docs/architecture/timekeeping-soa.md
# §3.1, §5.2, §6.1), against the consumer-side fake of Timekeeping, which
# checks every request against the entry API contract (§12.3). Each forwarded
# command carries the caller's claims, the admitted generation and an
# Idempotency-Key, answers the owner's entry for today's rendering, and writes
# nothing to timesheet_entries, the projection (§3.2). What the owner refuses
# is mapped to today's public error JSON (§5.1).
RSpec.describe Timekeeping::Gateway::Remote, type: :model do
  include TimekeepingCharacterization::Helpers
  include TimekeepingSingleWriterGuard

  let(:gateway) { Timekeeping::Gateway }

  let!(:fake) { TimekeepingContracts::FakeTimekeeping.new(generation: 3).install! }
  let(:tenant) { build_tenant }
  let(:other_tenant) { build_tenant }

  around do |example|
    config = Rails.configuration.x.timekeeping
    url, key = config.url, config.token_key
    config.url, config.token_key = TimekeepingContracts::FakeTimekeeping::URL, TimekeepingContracts::TEST_TOKEN_KEY
    example.run
  ensure
    config.url, config.token_key = url, key
    Current.reset
    Rails.event.clear_context
  end

  before do
    set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("re-cut over to Timekeeping"))
    Current.user = tenant.employee
  end

  after { expect(fake.violations).to be_empty }

  # An entry in the projection and in Timekeeping under the same id, as the
  # cutover leaves it (§10.3).
  def owned_entry(**attributes)
    unbilled_entry(tenant, **attributes).tap do |entry|
      fake.seed_entry(
        company_id: tenant.company.id, id: entry.id, project_id: entry.project_id, user_id: entry.user_id,
        duration: entry.duration, work_date: entry.work_date.iso8601, note: entry.note
      )
    end
  end

  def create_command(**attributes)
    gateway::CreateEntry.new(
      project: tenant.project, user: tenant.employee, writer: "web",
      attributes: ActionController::Parameters.new(duration: "90.7", work_date: "2026-11-02", note: "Forwarded", **attributes).permit!
    )
  end

  def forwarded(&command)
    result = nil
    writes = timesheet_entry_writes { result = gateway.call(command.call) }
    expect(writes).to eq([]), "the timekeeping owner wrote the projection"
    result
  end

  describe "CreateEntry" do
    it "creates the entry in Timekeeping and answers it for today's rendering" do
      entry = forwarded { create_command }

      owned = fake.entry(entry.id)
      expect(owned).to include(
        "company_id" => tenant.company.id, "project_id" => tenant.project.id, "user_id" => tenant.employee.id,
        "duration" => 90.7, "work_date" => "2026-11-02", "note" => "Forwarded", "agent_id" => nil
      )
      expect(entry).to be_readonly
      expect(entry).to have_attributes(id: owned["id"], duration: 90.7, work_date: Date.new(2026, 11, 2), bill_status: "unbilled", version: 1)
      expect(entry.snippet).to include(project: tenant.project.name, client: tenant.client.name, team_member: tenant.employee.full_name)
      expect(TimesheetEntry.where(id: entry.id)).to be_empty
    end

    it "carries the caller's claims, the admitted generation and an Idempotency-Key (§5.1, §6.1)" do
      Rails.event.set_context(request_id: "req-42")
      forwarded { create_command }

      call = fake.calls.sole
      expect(call.claims).to include(
        "sub" => "user:#{tenant.employee.id}", "company_id" => tenant.company.id, "role" => "employee",
        "timesheet_edit_days" => tenant.company.timesheet_edit_days, "actor" => { "type" => "user", "agent_id" => nil },
        "writer" => "web", "request_id" => "req-42",
        "project" => { "id" => tenant.project.id, "company_id" => tenant.company.id, "kept" => true, "billable" => true }
      )
      expect(call.input).to eq("entry" => {
        "duration" => 90.7, "work_date" => "2026-11-02", "note" => "Forwarded",
        "project_id" => tenant.project.id, "user_id" => tenant.employee.id
      })
    end

    it "sends the command's project and user over any the attributes name, as the legacy owner does" do
      forwarded { create_command(project_id: other_tenant.project.id, user_id: other_tenant.employee.id) }

      expect(fake.calls.sole.input.fetch("entry")).to include("project_id" => tenant.project.id, "user_id" => tenant.employee.id)
    end

    it "leaves out attributes the writer did not set, so the owner's defaults apply" do
      forwarded do
        gateway::CreateEntry.new(
          project: tenant.project, user: tenant.employee, writer: "cli",
          attributes: { duration: "30", work_date: "2026-11-02", note: nil, bill_status: nil, source: "cli", source_metadata: nil }
        )
      end

      expect(fake.calls.sole.input.fetch("entry").keys).to contain_exactly("duration", "work_date", "source", "project_id", "user_id")
    end

    it "acts as the agent for an agent's entry: the agent travels in the token, never in the body (W4)" do
      agent = create(:agent, company: tenant.company, user: tenant.employee, default_project: tenant.project)

      entry = forwarded do
        gateway::CreateEntry.new(
          project: tenant.project, user: agent.user, writer: "agent",
          attributes: { duration: "30", work_date: "2026-11-02", source: "automation", agent: }
        )
      end

      call = fake.calls.sole
      expect(call.claims).to include("actor" => { "type" => "agent", "agent_id" => agent.id }, "writer" => "agent")
      expect(call.input.fetch("entry")).not_to have_key("agent")
      expect(entry.agent).to eq(agent)
    end

    it "is the system actor when there is no Current.user, as the model's own checks read today" do
      Current.user = nil

      forwarded { create_command }

      expect(fake.calls.sole.claims).to include("sub" => "system", "role" => nil, "actor" => { "type" => "system", "agent_id" => nil })
    end
  end

  describe "UpdateEntry and DiscardEntry" do
    let!(:entry) { owned_entry(note: "Before") }

    it "updates through the owner, the command's project first, and answers the owner's entry" do
      updated = forwarded do
        gateway::UpdateEntry.new(
          entry:, project: tenant.project, writer: "cli",
          attributes: { duration: "45", work_date: "2026-11-03", note: "After" }
        )
      end

      expect(fake.calls.sole.input).to eq("entry" => {
        "project_id" => tenant.project.id, "duration" => 45.0, "work_date" => "2026-11-03", "note" => "After"
      })
      expect(fake.calls.sole.claims).to include("writer" => "cli")
      expect(updated).to have_attributes(id: entry.id, note: "After", duration: 45.0, version: 2)
      expect(entry.reload.note).to eq("Before")
    end

    it "discards through the owner" do
      discarded = forwarded { gateway::DiscardEntry.new(entry:, writer: "mobile") }

      expect(fake.entry(entry.id)["discarded_at"]).to be_present
      expect(discarded).to be_discarded
      expect(fake.calls.sole.claims).to include("writer" => "mobile", "project" => include("id" => entry.project_id))
      expect(entry.reload).not_to be_discarded
    end

    it "answers an entry the owner does not hold as today's 404 shape" do
      stray = unbilled_entry(tenant)

      expect { gateway.call(gateway::DiscardEntry.new(entry: stray, writer: "web")) }
        .to raise_error(gateway::Refused, "Not found") { |error| expect(error.status).to eq(404) }
    end
  end

  describe "refusals, as today's public error JSON (§5.1)" do
    it "answers a model validation as today's first full message, with 422" do
      fake.fail_next(:create_entry, status: 422, slug: "validation-failed", retryable: false,
        errors: { "duration" => ["must be less than or equal to 6000000"] })

      expect { gateway.call(create_command) }.to raise_error(gateway::Refused, "Duration must be less than or equal to 6000000") { |error|
        expect(error.status).to eq(422)
      }
    end

    it "answers a stale generation as the retryable ownership-moving refusal (§9.3)" do
      fake.generation = 4

      expect { gateway.call(create_command) }.to raise_error(Timekeeping::Ownership::Moving, I18n.t("timesheet_entry.ownership_moving"))
    end

    it "answers a locked entry as Locked, with 403, so a writer can give today's locked answer" do
      fake.fail_next(:create_entry, status: 403, slug: "entry-locked", retryable: false)

      expect { gateway.call(create_command) }.to raise_error(gateway::Locked, "Entry locked") { |error| expect(error.status).to eq(403) }
    end

    it "answers any other problem with its own status" do
      fake.fail_next(:create_entry, status: 403, slug: "forbidden", retryable: false)

      expect { gateway.call(create_command) }.to raise_error(gateway::Refused, "Forbidden") { |error|
        expect(error).not_to be_a(gateway::Locked)
        expect(error.status).to eq(403)
      }
    end

    it "refuses a request the contract cannot carry with 422, and sends nothing" do
      command = create_command(bill_status: "invoiced")

      expect { gateway.call(command) }.to raise_error(gateway::Refused, /bill_status/) { |error| expect(error.status).to eq(422) }
      expect(fake.calls).to be_empty
    end

    it "raises Unavailable, a retryable 503, when Timekeeping stays down" do
      WebMock::API.stub_request(:post, %r{/internal/v1/entries\z}).to_return(status: 503, body: "")
      allow(Timekeeping::EntryClient).to receive(:new).and_wrap_original { |original| original.call(backoff: ->(_) { }) }

      expect { gateway.call(create_command) }.to raise_error(Timekeeping::EntryClient::Unavailable, /HTTP 503/)
    end
  end

  describe "BulkMove and BulkDiscard (W2)" do
    let!(:first) { owned_entry(note: "First") }
    let!(:second) { owned_entry(note: "Second") }
    let(:target) { create(:project, client: tenant.client, billable: true) }

    def bulk_move(*entries) = gateway::BulkMove.new(entries: TimesheetEntry.where(id: entries.map(&:id)), project: target)

    it "moves the caller's entries through the owner as the bulk writer, and answers the owner's entries" do
      moved = forwarded { bulk_move(first, second) }

      call = fake.calls.sole
      expect(call.input).to match("ids" => contain_exactly(first.id, second.id), "project_id" => target.id)
      expect(call.claims).to include(
        "writer" => "bulk", "company_id" => tenant.company.id, "sub" => "user:#{tenant.employee.id}",
        "project" => include("id" => target.id, "company_id" => tenant.company.id)
      )
      expect(moved).to all(be_readonly)
      expect(moved.map { |entry| [entry.id, entry.project_id, entry.version] })
        .to contain_exactly([first.id, target.id, 2], [second.id, target.id, 2])
      expect([first, second].map { |entry| entry.reload.project_id }).to all(eq(tenant.project.id))
    end

    it "answers a skipped entry as the owner holds it, unmoved (A9: skipped, never refused)" do
      moved_first = fake.entry(first.id).merge("project_id" => target.id, "version" => 2)
      WebMock::API.stub_request(:post, %r{/internal/v1/entries/bulk_move\z}).to_return(
        status: 200, headers: { "content-type" => "application/json" },
        body: JSON.generate("moved_ids" => [first.id], "skipped_ids" => [second.id], "entries" => [moved_first, fake.entry(second.id)])
      )

      answered = forwarded { bulk_move(first, second) }

      expect(answered.to_h { |entry| [entry.id, entry.project_id] }).to eq(first.id => target.id, second.id => tenant.project.id)
    end

    it "discards through the owner in the command's tenant, and answers the ids it discarded" do
      discarded = forwarded { gateway::BulkDiscard.new(entries: TimesheetEntry.where(id: first.id), company: tenant.company) }

      expect(discarded).to eq([first.id])
      expect(fake.entry(first.id)["discarded_at"]).to be_present
      expect(fake.entry(second.id)["discarded_at"]).to be_nil
      expect(fake.calls.sole.claims).to include("writer" => "bulk", "company_id" => tenant.company.id, "project" => nil)
      expect(first.reload).not_to be_discarded
    end

    it "touches nothing of another tenant: the owner scopes by the token's company (§6.3)" do
      discarded = forwarded { gateway::BulkDiscard.new(entries: TimesheetEntry.where(id: first.id), company: other_tenant.company) }

      expect(discarded).to eq([])
      expect(fake.entry(first.id)["discarded_at"]).to be_nil
    end

    it "makes no call for no entries, which select nothing" do
      expect(forwarded { gateway::BulkDiscard.new(entries: TimesheetEntry.none, company: tenant.company) }).to eq([])
      expect(forwarded { bulk_move }).to eq([])
      expect(fake.calls).to be_empty
    end

    it "answers the owner's lock refusal as Locked (A9 in the write transaction, §6.2)" do
      fake.fail_next(:bulk_move, status: 403, slug: "entry-locked", retryable: false)

      expect { gateway.call(bulk_move(first)) }.to raise_error(gateway::Locked) { |error| expect(error.status).to eq(403) }
      expect(fake.entry(first.id)["project_id"]).to eq(tenant.project.id)
    end
  end

  describe "DetachAgent (W6)" do
    let(:agent) { create(:agent, company: tenant.company, user: tenant.employee) }

    def held(tenant, **attributes)
      fake.seed_entry(
        company_id: tenant.company.id, project_id: tenant.project.id, user_id: tenant.employee.id,
        duration: 30.0, work_date: "2026-11-02", **attributes
      )
    end

    it "detaches the agent's entries in the agent's company as the agent_destroy writer, and answers their ids" do
      named = held(tenant, agent_id: agent.id)
      unnamed = held(tenant)

      detached = forwarded { gateway::DetachAgent.new(agent:) }

      expect(detached).to eq([named["id"]])
      expect(fake.entry(named["id"])).to include("agent_id" => nil, "version" => 2)
      expect(fake.entry(unnamed["id"])).to eq(unnamed)
      expect(fake.calls.sole.claims).to include(
        "writer" => "agent_destroy", "company_id" => tenant.company.id, "project" => nil,
        "sub" => "user:#{tenant.employee.id}", "actor" => { "type" => "user", "agent_id" => nil }
      )
    end

    it "touches nothing of another tenant: the owner scopes by the agent's company (§6.3)" do
      foreign = held(other_tenant, agent_id: agent.id)

      expect(forwarded { gateway::DetachAgent.new(agent:) }).to eq([])
      expect(fake.entry(foreign["id"])).to eq(foreign)
    end

    it "is the system actor when no user is signed in, as for a destroy from a job or the console" do
      Current.user = nil

      forwarded { gateway::DetachAgent.new(agent:) }

      expect(fake.calls.sole.claims).to include("sub" => "system", "role" => nil, "writer" => "agent_destroy")
    end
  end

  describe "ImportBatch (W5)" do
    let(:batch_path) { %r{\A#{Regexp.escape(TimekeepingContracts::FakeTimekeeping::URL)}/internal/v1/imports/41-run/batches/2\z}o }

    before { Current.user = nil }

    def row(**attributes)
      {
        project: tenant.project, user: tenant.employee, duration: 75, work_date: Date.new(2026, 1, 2),
        note: "Imported", bill_status: "unbilled", source: "import", source_metadata: { tool: "harvest" }, **attributes
      }
    end

    def batch(*rows) = gateway::ImportBatch.new(company: tenant.company, import_id: "41-run", batch_no: 2, rows:)

    it "writes the batch in the importing company as the system import writer, and answers what it created" do
      result = forwarded { batch(row, row(note: "Invoiced", bill_status: "billed")) }

      expect(result).to eq(gateway::ImportBatch::Result.new(created_ids: [1, 2], row_errors: {}))
      expect(fake.entry(1)).to include(
        "company_id" => tenant.company.id, "project_id" => tenant.project.id, "user_id" => tenant.employee.id,
        "duration" => 75.0, "work_date" => "2026-01-02", "note" => "Imported", "bill_status" => "unbilled",
        "source" => "import", "source_metadata" => { "tool" => "harvest" }, "agent_id" => nil
      )
      expect(fake.entry(2)).to include("note" => "Invoiced", "bill_status" => "billed")
      expect(fake.calls.sole.claims).to include(
        "sub" => "system", "role" => nil, "writer" => "import", "company_id" => tenant.company.id, "project" => nil
      )
    end

    it "is idempotent by import_id:batch_no, so a retry after a lost response replays the batch (§3.4, §9.4)" do
      fake.lose_next_response(:import_batch)

      result = forwarded { batch(row) }

      expect(result.created_ids).to eq([1])
      expect(fake.calls.map(&:operation)).to eq(%i[import_batch import_batch])
      expect(fake.entry(2)).to be_nil
      expect(WebMock).to have_requested(:post, batch_path).with(headers: { "Idempotency-Key" => "41-run:2" }).twice
    end

    it "answers each row the owner rejected with today's message, by its index in the batch, in row order" do
      failed_rows = [
        { "index" => 2, "errors" => { "base" => ["Project is not billable"] } },
        { "index" => 0, "errors" => { "duration" => ["must be less than or equal to 6000000", "is invalid"] } }
      ]
      WebMock::API.stub_request(:post, batch_path).to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate("created_ids" => [9], "failed_rows" => failed_rows)
      )

      result = forwarded { batch(row(duration: 7_000_000), row, row) }

      expect(result.created_ids).to eq([9])
      expect(result.row_errors.to_a).to eq([
        [0, "Duration must be less than or equal to 6000000 and Duration is invalid"],
        [2, "Project is not billable"]
      ])
    end
  end

  it "refuses the commands it does not forward yet, and writes nothing" do
    entry = unbilled_entry(tenant)
    writes = timesheet_entry_writes do
      expect { gateway.call(gateway::MarkBilled.new(entries: TimesheetEntry.where(id: entry.id))) }
        .to raise_error(gateway::OwnerUnavailable, /owner timekeeping .* MarkBilled refused/)
    end

    expect(writes).to eq([])
    expect(fake.calls).to be_empty
  end
end
