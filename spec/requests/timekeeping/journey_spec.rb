# frozen_string_literal: true

require "rails_helper"

# The end-to-end journey driver (Timekeeping::Journey; docs/architecture/
# timekeeping-soa.md §13 item 1), run in process through the real controllers
# on two tenants. Its client hands each request to this app instead of the
# network, and the handoffs are stand-ins, so every stage runs under the
# legacy owner: these examples pin the journey's own sequence of writes and
# checks, and that each check fails the run when what it checks does not
# hold. The journey across the real owners runs against the two running
# applications of the local demo (bin/timekeeping-demo journey).
RSpec.describe Timekeeping::Journey, type: :request do
  include TimekeepingCharacterization::Helpers

  let(:password) { "Password123!" }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let(:tenants) do
    # The journey finds each business by its name, as it finds the seeded ones.
    [tenant_a, tenant_b].each_with_index.map do |tenant, index|
      # Reports need pro access, as the seeded businesses have.
      tenant.company.update!(name: "Journey business #{index + 1}", plan_tier: "paid")
      { name: tenant.company.name, employee: tenant.employee.email, admin: tenant.admin.email }
    end
  end
  let(:stages) { described_class::STAGES.map { |stage| stage.merge(owner: "legacy") } }
  let(:handoffs) { [] }
  # What a stand-in handoff does to the data, by handoff name.
  let(:during_handoff) { {} }
  let(:handoff) do
    lambda do |name|
      handoffs << name
      during_handoff[name]&.call
    end
  end
  let(:log) { StringIO.new }

  let(:transport) do
    lambda do |request|
      headers = request.each_capitalized.to_h.except("Host", "Content-Length", "Accept-Encoding", "User-Agent")
      # The journey's client keeps no cookies; sign-in sets a session one,
      # which would otherwise sign every later request in as that user.
      reset!
      public_send(request.method.downcase, request.path, params: request.body, headers:)
      [response.status, response.content_type.to_s, response.body]
    end
  end

  let(:journey) do
    described_class.new(
      client: described_class::Client.new(base_url: "http://www.example.com", transport:), password:, handoff:,
      logger: Logger.new(log), options: described_class::Options.new(pdf: false, wait: 2, tenants:, stages:)
    )
  end

  def journey_invoices(tenant) = Invoice.where(company: tenant.company).where("invoice_number LIKE 'JRN-%'")

  it "writes and checks every stage on both tenants, with a handoff between each" do
    result = journey.call

    expect(handoffs).to eq(%w[first_cutover rollback recutover])
    [tenant_a, tenant_b].zip(result).each do |tenant, journeyed|
      expect(journeyed[:entries].size).to eq(16)
      stored = TimesheetEntry.where(id: journeyed[:entries].map(&:id)).index_by(&:id)
      expect(stored.values.map(&:user_id).uniq).to eq([tenant.employee.id])
      journeyed[:entries].each do |entry|
        expect(stored.fetch(entry.id)).to have_attributes(note: entry.note, duration: entry.duration)
        expect(stored.fetch(entry.id).locked).to eq(entry.reserved)
      end

      invoices = journey_invoices(tenant).includes(:invoice_line_items)
      expect(invoices.map(&:status).uniq).to eq(["draft"])
      expect(invoices.size).to eq(8)
      grouped = invoices.select { |invoice| invoice.invoice_number.end_with?("grouped") }
      expect(grouped.map { |invoice| invoice.invoice_line_items.sole.timesheet_entry_id }).to all(be_nil)
    end

    # Each stage edits the entry the stage before created.
    second_stage = result.first[:entries].find { |entry| entry.note.start_with?("Journey 2 edited") }
    expect(second_stage.note).to eq("Journey 2 edited, again in stage 3")
    expect(log.string).to include("journey complete")
  end

  it "starts only before any handoff, and then writes nothing" do
    Timekeeping::Ownership.current.update!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("first handoff aborted"))

    expect { journey.call }.to raise_error(described_class::Failed, /freshly seeded demo/)
    expect(TimesheetEntry.count).to eq(0)
    expect(handoffs).to be_empty
  end

  it "stops when a stage is not under the owner the handoff before it left" do
    stages[1] = stages[1].merge(owner: "timekeeping")

    expect { journey.call }.to raise_error(described_class::Failed, /expected the timekeeping owner .*owner legacy/)
    expect(handoffs).to eq(%w[first_cutover])
  end

  it "fails when a handoff changes a billing value, and runs no further handoff" do
    during_handoff["rollback"] = -> { journey_invoices(tenant_b).first.update_columns(tax: 1) }

    expect { journey.call }.to raise_error(described_class::Failed, /the rollback handoff changed money: .*table: "invoices", id: "\d+", column: "tax", before: "0.00", after: "1.00"/)
    expect(handoffs).to eq(%w[first_cutover rollback])
  end

  it "fails when an entry accepted before a handoff does not read back as last written after it" do
    during_handoff["first_cutover"] = -> { TimesheetEntry.where(user: tenant_a.employee).order(:id).first.update_columns(note: "lost") }

    expect { journey.call }.to raise_error(described_class::Failed, /entry \d+ is not as last written/)
  end

  it "fails when a reserved entry is offered as a candidate again after a handoff" do
    # Under the legacy owner a kept invoice's lines are what keeps its entries
    # out of the candidates. Discarding the draft behind the API frees its
    # entry and leaves every value the money check reads as it was.
    during_handoff["first_cutover"] = lambda do
      journey_invoices(tenant_a).find_by!("invoice_number LIKE '%-direct'").update_columns(discarded_at: Time.current)
    end

    expect { journey.call }.to raise_error(described_class::Failed, /candidates leave out the reserved entries/)
  end

  it "fails when a handoff runner stops, as its task does, with the runner's message" do
    during_handoff["first_cutover"] = -> { abort "Timekeeping first_cutover stopped: unreachable" }

    expect { journey.call }.to raise_error(described_class::Failed, /the first_cutover handoff stopped: Timekeeping first_cutover stopped: unreachable/)
  end

  it "fails when the time-entries report does not show the entries the stage wrote" do
    allow(Reports::TimeEntries::Result).to receive(:process).and_return([])

    expect { journey.call }.to raise_error(described_class::Failed, /timed out after 2 s waiting until the time-entries report shows entries/)
  end

  describe described_class::Client do
    it "sends JSON to the application at its base URL and answers status, type and body" do
      stub = stub_request(:post, "http://miru.test:3000/api/v1/invoices")
        .with(body: { invoice: { status: "draft" } }.to_json, headers: { "Content-Type" => "application/json", "X-Auth-Email" => "a@b.example" })
        .to_return(status: 422, body: '{"errors":"nope"}', headers: { "Content-Type" => "application/json" })

      response = described_class.new(base_url: "http://miru.test:3000")
        .call(:post, "/api/v1/invoices", body: { invoice: { status: "draft" } }, headers: { "X-Auth-Email" => "a@b.example" })

      expect(stub).to have_been_requested
      expect(response).to have_attributes(status: 422, content_type: "application/json")
      expect(response.json).to eq("errors" => "nope")
    end
  end
end
