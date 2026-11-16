# frozen_string_literal: true

require "rails_helper"

# The alternating-writers driver (Timekeeping::AlternatingWriters; docs/
# architecture/timekeeping-soa.md §12.4), run in process through the real
# controllers, MCP endpoint, agent API, importer and models, on two tenants.
# Its client hands each request to this app instead of the network, and the
# handoffs are stand-ins, so every stage runs under the legacy owner: these
# examples pin the driver's own sequence of writes and checks, and that each
# check fails the run when what it checks does not hold. The run across the
# real owners is against the two running applications of the local demo
# (bin/timekeeping-demo alternating-writers).
RSpec.describe Timekeeping::AlternatingWriters, type: :request do
  include TimekeepingCharacterization::Helpers

  let(:password) { "Password123!" }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let(:tenants) do
    [tenant_a, tenant_b].each_with_index.map do |tenant, index|
      # MCP is a Pro feature, as the seeded businesses have it.
      tenant.company.update!(name: "Alternating business #{index + 1}", plan_tier: "paid")
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
      # The client keeps no cookies; sign-in sets a session one, which would
      # otherwise sign every later request in as that user.
      reset!
      public_send(request.method.downcase, request.path, params: request.body, headers:)
      # The MCP endpoint calls the application again in process
      # (app/mcp/api_proxy.rb). Inside this test process that nested call
      # leaves the execution context with no current attributes, which the
      # writers this driver runs in process (the importer's audited writes)
      # then need. A server process starts each request afresh.
      ActiveSupport::ExecutionContext.clear if ActiveSupport::ExecutionContext.current_attributes_instances.nil?
      [response.status, response.content_type.to_s, response.body]
    end
  end

  let(:run) do
    described_class.new(
      client: Timekeeping::PublicApi::Client.new(base_url: "http://www.example.com", transport:), password:, handoff:,
      logger: Logger.new(log), options: described_class::Options.new(wait: 2, tenants:, stages:)
    )
  end

  def written(tenant, writer, stage)
    TimesheetEntry.find_by!("note LIKE ?", "Alternating #{tenant.company.id}-#{stage} #{writer}%")
  end

  it "runs every writer in every stage on both tenants, each on what another wrote before the handoff" do
    result = run.call

    expect(handoffs).to eq(%w[first_cutover rollback recutover])
    [tenant_a, tenant_b].zip(result).each do |tenant, ran|
      expect(ran[:entries].size).to eq(28)
      expect(ran[:entries].group_by(&:writer).transform_values(&:size))
        .to eq("web" => 4, "mobile" => 4, "cli" => 4, "mcp" => 4, "agent" => 4, "import" => 4, "import billed" => 4)
      entries = TimesheetEntry.where(id: ran[:entries].map(&:id)).index_by(&:id)
      expect(entries.values.map(&:user_id).uniq).to eq([tenant.employee.id])

      by = ->(writer, stage) { entries.fetch(ran[:entries].find { |entry| entry.writer == writer && entry.stage == stage }.id) }
      other_project = ran[:other_project]
      expect(other_project).to have_attributes(client_id: tenant.client.id, billable: true)

      (1..3).each do |stage|
        later = stage + 1
        # W1 web edited the MCP entry, W1 mobile the web entry, W3 the
        # imported one and W3a the CLI one, each a stage later.
        expect(by.call("mcp", stage).note).to end_with("edited with web in stage #{later}")
        expect(by.call("web", stage).note).to end_with("edited with mobile in stage #{later}")
        # The import's source_metadata names its tool, so once the CLI edit
        # drops the "import" source the model infers "automation"
        # (TimesheetEntry#inferred_source), under every owner.
        expect(by.call("import", stage)).to have_attributes(source: "automation", project_id: other_project.id)
        expect(by.call("import", stage).note).to end_with("edited with the CLI in stage #{later}")
        # miru.time.update sends no source_metadata, so the entry keeps the
        # CLI's source.
        expect(by.call("cli", stage)).to have_attributes(source: "cli", project_id: other_project.id)
        expect(by.call("cli", stage).note).to end_with("edited with MCP in stage #{later}")
        # W2 discarded the mobile entry, W6 detached the agent's entry, and
        # W7 deleted the draft that held it. Under the legacy owner the
        # draft's discard re-locks it (K2, §2.3 L2): F2 releases it only
        # under the timekeeping and monolith owners. No kept invoice holds it,
        # so the candidates offer it again either way.
        expect(by.call("mobile", stage)).to be_discarded
        expect(by.call("agent", stage)).to have_attributes(agent_id: nil, locked: true, source: "automation")
      end
      expect(by.call("import billed", 2)).to have_attributes(bill_status: "billed", source: "import")
      expect(by.call("agent", 4)).to have_attributes(agent_id: Agent.find_by!(company: tenant.company, name: "Alternating writers 4").id, locked: true)
      expect(Agent.where(company: tenant.company).pluck(:name)).to eq(["Alternating writers 4"])

      # A discard renumbers its draft (Invoice#update_invoice_number), so
      # they are found by the ids the run kept.
      drafts = Invoice.with_discarded.find(ran[:stages].map { |stage| stage[:draft] })
      expect(drafts.map { |draft| [draft.company_id, draft.status, draft.discarded?] })
        .to eq([[tenant.company.id, "draft", true]] * 3 + [[tenant.company.id, "draft", false]])
      expect(drafts.last.invoice_line_items.sole.timesheet_entry_id).to eq(by.call("agent", 4).id)
    end
    expect(log.string).to include("alternating writers complete")
  end

  it "moves entries to a project the employee is already on when the client has one, and adds none" do
    other = create(:project, client: tenant_a.client, billable: true)
    create(:project_member, project: other, user: tenant_a.employee)
    stages.replace(stages.first(2))

    result = run.call

    expect(result.first[:other_project]).to eq(other)
    expect(Project.where(client: tenant_a.client).count).to eq(2)
  end

  it "starts only before any handoff, and then writes nothing" do
    Timekeeping::Ownership.current.update!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rolled back to the prepared application"))

    expect { run.call }.to raise_error(described_class::Failed, /alternating writers starts from a freshly seeded demo/)
    expect(TimesheetEntry.count).to eq(0)
    expect(handoffs).to be_empty
  end

  it "stops when a stage is not under the owner the handoff before it left" do
    stages[1] = stages[1].merge(owner: "monolith")

    expect { run.call }.to raise_error(described_class::Failed, /expected the monolith owner .*owner legacy/)
    expect(handoffs).to eq(%w[first_cutover])
  end

  it "fails when an entry written before a handoff is not as last written after it" do
    during_handoff["rollback"] = -> { written(tenant_b, "agent", 2).update_columns(agent_id: nil) }

    expect { run.call }.to raise_error(described_class::Failed, /entry \d+ \(agent, stage 2\) is not as last written: expected .*agent_id: \d+/)
    expect(handoffs).to eq(%w[first_cutover rollback])
  end

  it "fails when an entry discarded before a handoff is held again after it" do
    during_handoff["recutover"] = -> { written(tenant_a, "mobile", 2).update_columns(discarded_at: nil) }

    expect { run.call }.to raise_error(described_class::Failed, /entry \d+ \(mobile, stage 2\) was discarded, but the owner still holds it/)
  end

  it "fails when a handoff changes a billing value" do
    during_handoff["first_cutover"] = -> { Invoice.where(company: tenant_a.company).sole.update_columns(tax: 1) }

    expect { run.call }.to raise_error(described_class::Failed, /the first_cutover handoff changed money: .*column: "tax"/)
  end

  it "fails when the entry a draft holds is offered as a candidate again" do
    during_handoff["first_cutover"] = -> { Invoice.where(company: tenant_b.company).sole.update_columns(discarded_at: Time.current) }

    expect { run.call }.to raise_error(described_class::Failed, /candidates leave out the reserved entries/)
  end

  it "fails when a writer's create leaves another source than that writer's" do
    allow(Api::V1::Cli::TimesheetEntriesController).to receive(:new).and_wrap_original do |original, *args|
      original.call(*args).tap do |controller|
        controller.define_singleton_method(:create_attributes) { super().merge(source: "manual") }
      end
    end

    expect { run.call }.to raise_error(described_class::Failed, /the cli entry \d+ was created with source "manual", not cli/)
  end

  it "fails when the import does not import both rows" do
    # A second team member with the employee's name makes the rows ambiguous.
    namesake = member_of(tenant_a.company, role: :employee)
    namesake.update!(first_name: tenant_a.employee.first_name, last_name: tenant_a.employee.last_name)

    expect { run.call }.to raise_error(described_class::Failed, /the W5 import for Alternating business 1 did not import both rows: completed, 0 imported/)
  end
end
