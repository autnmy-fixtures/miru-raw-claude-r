# frozen_string_literal: true

require "csv"

# The alternating-writers proof of docs/architecture/timekeeping-soa.md §12.4,
# against the two running applications of the local demo (§11.2):
#
#   Alternating writers across cutover, rollback and re-cutover, on both
#   tenants, through every writer.
#
# From a freshly seeded demo it writes a stage under each owner in turn
# (legacy, timekeeping, monolith, timekeeping), on both seeded businesses,
# and runs each handoff with its own runner between stages, exactly as the
# journey does (Timekeeping::DemoHandoffs). In every stage each writer of
# §1.3 writes, and from the second stage on each one writes an entry that
# another writer wrote under the owner before the handoff:
#
#   W6 agent destroy  the previous stage's agent is destroyed, which detaches
#                     its entry, still held by the previous stage's draft
#   W7 invoices       the admin deletes the previous stage's draft, which
#                     releases that agent entry
#   W1 web            the employee creates an entry, and edits the entry MCP
#                     created in the previous stage
#   W1 mobile         creates one, and edits the previous stage's web entry
#   W3 CLI            creates one, and edits the previous stage's imported
#                     entry
#   W3a MCP           creates one with miru.time.create, and edits the
#                     previous stage's CLI entry with miru.time.update
#   W2 bulk           moves the previous stage's CLI and imported entries to
#                     the business's other project, and discards the
#                     previous stage's mobile entry
#   W4 agent API      a new agent of the employee's creates an entry
#   W5 Harvest import imports an unbilled and a billed row for the employee
#   W7 invoices       the admin saves a draft with a direct line for this
#                     stage's agent entry, which reserves it
#
# The first stage has no earlier owner, so in it W2, W6 and the release only
# have nothing to act on, and the other writers only create.
#
# W1, W2, W3, W3a and W7 go over the existing application's public HTTP API,
# as each business's own users (Timekeeping::PublicApi), the CLI and MCP with
# a CLI session's token. W4 goes over the agent API with an agent key. The
# agents and their keys are made here, in process, because the existing
# application has no API for them. W5 and W6 have no HTTP entry point: W5 runs
# the importer as the imports:harvest_time_entries task does, and W6 destroys
# the agent through its model, both in this process (the existing
# application's). Every write still goes through the write gateway to
# whichever owner holds the entries.
#
# After each stage, and again after each handoff, on each business:
#
#   kept         every entry written so far reads back through the owner
#                (Timekeeping::EntryReads) as last written: note, duration,
#                project, agent, bill status and source, and a discarded one
#                is not found
#   projection   timesheet_entries catches up to the same values, a
#                discarded entry discarded (under Timekeeping it waits for
#                the relay)
#   reservations the invoice candidates leave out the entry the current
#                draft holds and offer every kept, unbilled, unreserved one
#
# and around each handoff the financial snapshot must be identical.
#
# It starts only from a freshly seeded demo, before any handoff, and does not
# resume: like the journey, a handoff that stops leaves its journal for its
# own runner, and the next run needs a fresh demo. Any check that does not
# hold raises Failed, and the run stops there.
class Timekeeping::AlternatingWriters
  include Timekeeping::PublicApi
  include Timekeeping::DemoHandoffs

  class Failed < StandardError; end

  STAGES = Timekeeping::DemoHandoffs::STAGES

  # The source each writer's create leaves on its entry (TimesheetEntry
  # #inferred_source; K10 for MCP).
  CREATED_SOURCE = {
    "web" => "manual", "mobile" => "manual", "cli" => "cli", "mcp" => "mcp", "agent" => "automation", "import" => "import"
  }.freeze

  # What the run wrote, per business, to check under every later owner.
  # reserved: the draft holding it, if any.
  Entry = Struct.new(
    :id, :writer, :stage, :note, :duration, :project_id, :agent_id, :bill_status, :source, :discarded, :reserved,
    keyword_init: true
  ) do
    def expected = { note:, duration: duration.to_d.round(5), project_id:, agent_id:, bill_status:, source: }
  end

  # What a run may change: wait is how long, in seconds, a check waits on a
  # worker; tenants default to the seeded businesses, stages to the three
  # handoffs.
  Options = Data.define(:wait, :tenants, :stages) do
    def initialize(wait: DEFAULT_WAIT, tenants: TENANTS, stages: STAGES) = super
  end

  # handoff: called with a STAGES handoff name; runs that handoff to its end
  # or raises.
  def initialize(client:, password:, handoff:, logger: Rails.logger, options: Options.new)
    @client = client
    @password = password
    @handoff = handoff
    @logger = logger
    @options = options
    @sessions = {}
    @cli_tokens = {}
  end

  def call
    ensure_fresh!
    tenants = @options.tenants.map { |tenant| prepare(tenant) }

    @options.stages.each_with_index do |stage, index|
      say "stage #{index + 1}: under the #{stage[:owner]} owner"
      ensure_owner!(stage[:owner])
      tenants.each { |tenant| run_stage(tenant, index + 1) }
      next unless stage[:handoff]

      hand_off(stage[:handoff])
      tenants.each { |tenant| check(tenant, "#{tenant[:name]}, after the #{stage[:handoff]} handoff") }
    end

    say "alternating writers complete: #{summary(tenants)}"
    tenants
  end

  private

    def log_prefix = "alternating writers"

    def wait = @options.wait

    # The seeded business, and a second project of the same client the
    # employee is on, for W2 to move entries to. A business whose employee is
    # on only one gets one, before any handoff: a catalogue write, never an
    # entry write.
    def prepare(tenant)
      prepared = prepare_tenant(tenant)
      employee = User.find(prepared[:employee_id])
      admin = User.find_by!(email: tenant[:admin])
      prepared.merge(employee_user: employee, admin_user: admin, other_project: other_project(prepared, employee), stages: [])
    end

    def other_project(tenant, employee)
      project = tenant[:project]
      employee.project_members.kept.includes(:project).map(&:project).find do |candidate|
        candidate.id != project.id && candidate.kept? && candidate.billable && candidate.client_id == project.client_id
      end || create_other_project(project, employee)
    end

    def create_other_project(project, employee)
      rate = employee.project_members.kept.find_by!(project:).hourly_rate
      Project.create!(client: project.client, name: "#{project.name} (alternating)"[0, 30], billable: true).tap do |other|
        ProjectMember.create!(project: other, user: employee, hourly_rate: rate)
        say "#{project.client.name}: added the project #{other.name} for W2's moves"
      end
    end

    def run_stage(tenant, number)
      label = "#{tenant[:name]}, stage #{number}"
      previous = tenant[:stages].last
      current = { number:, entries: {} }
      tenant[:stages] << current

      write(tenant, current, previous, label)
      say "#{label}: #{current[:entries].keys.join(', ')} created#{', the previous stage\'s entries written' if previous}"
      check(tenant, label)
    end

    # Every writer, in the order the class comment gives.
    def write(tenant, current, previous, label)
      if previous
        destroy_agent(previous, label)
        release_draft(tenant, previous, label)
      end
      web(tenant, current, previous)
      mobile(tenant, current, previous)
      cli(tenant, current, previous)
      mcp(tenant, current, previous)
      bulk(tenant, previous, label) if previous
      agent(tenant, current)
      import(tenant, current)
      reserve(tenant, current, label)
    end

    # --- writers --------------------------------------------------------

    # W1 web: creates, and edits the previous stage's MCP entry.
    def web(tenant, current, previous)
      created = create_with(tenant, current, "web", "/api/v1/timesheet_entry")
      update_with(tenant, previous[:entries].fetch("mcp"), "web", "/api/v1/timesheet_entry", current) if previous
      created
    end

    # W1 mobile: creates, and edits the previous stage's web entry.
    def mobile(tenant, current, previous)
      create_with(tenant, current, "mobile", "/api/v1/mobile/timesheet_entries")
      update_with(tenant, previous[:entries].fetch("web"), "mobile", "/api/v1/mobile/timesheet_entries", current) if previous
    end

    def create_with(tenant, current, writer, path)
      note = note_for(tenant, current, writer)
      response = as(tenant, :employee).call(:post, path, body: entry_body(tenant, duration: 50.5, note:))
      expect_ok!(response, "create an entry with W1 #{writer} for #{tenant[:name]}")
      record(tenant, current, writer, response.json.fetch("entry"))
    end

    def update_with(tenant, entry, writer, path, current)
      note = "#{entry.note}; edited with #{writer} in stage #{current[:number]}"
      body = {
        project_id: entry.project_id,
        timesheet_entry: { duration: entry.duration + 1, note:, work_date: Date.current.iso8601, bill_status: entry.bill_status }
      }
      response = as(tenant, :employee).call(:patch, "#{path}/#{entry.id}", body:)
      expect_ok!(response, "edit entry #{entry.id} with W1 #{writer}")
      written(entry, response.json.fetch("entry"))
    end

    # W3 CLI: creates, and edits the previous stage's imported entry.
    def cli(tenant, current, previous)
      body = cli_body(tenant[:project].id, 40, note_for(tenant, current, "cli"))
      response = cli_call(tenant, :post, "/api/v1/cli/timesheet_entries", body)
      expect_ok!(response, "create an entry with W3 CLI for #{tenant[:name]}")
      record(tenant, current, "cli", response.json.fetch("entry"))
      return unless previous

      entry = previous[:entries].fetch("import")
      body = cli_body(entry.project_id, entry.duration + 2, "#{entry.note}; edited with the CLI in stage #{current[:number]}")
      response = cli_call(tenant, :patch, "/api/v1/cli/timesheet_entries/#{entry.id}", body)
      expect_ok!(response, "edit entry #{entry.id} with W3 CLI")
      written(entry, response.json.fetch("entry"))
    end

    def cli_body(project_id, duration, note)
      { timesheet_entry: { project_id:, duration_minutes: duration, work_date: Date.current.iso8601, note:, bill_status: "unbilled" } }
    end

    # W3a MCP: creates, and edits the previous stage's CLI entry.
    def mcp(tenant, current, previous)
      arguments = { project_id: tenant[:project].id, duration_minutes: 35, work_date: Date.current.iso8601,
                    note: note_for(tenant, current, "mcp"), bill_status: "unbilled" }
      record(tenant, current, "mcp", mcp_tool(tenant, "miru.time.create", arguments))
      return unless previous

      entry = previous[:entries].fetch("cli")
      arguments = { id: entry.id, project_id: entry.project_id, duration_minutes: entry.duration + 3, work_date: Date.current.iso8601,
                    note: "#{entry.note}; edited with MCP in stage #{current[:number]}" }
      written(entry, mcp_tool(tenant, "miru.time.update", arguments))
    end

    # W2 bulk: moves the previous stage's CLI and imported entries to the
    # other project, and discards the previous stage's mobile entry.
    def bulk(tenant, previous, label)
      moved = previous[:entries].values_at("cli", "import")
      response = as(tenant, :employee).call(:patch, "/api/v1/timesheet_entry/bulk_action",
        body: { ids: moved.map(&:id), project_id: tenant[:other_project].id })
      expect_ok!(response, "bulk move entries #{moved.map(&:id)}")
      moved.each { |entry| entry.project_id = tenant[:other_project].id }

      discarded = previous[:entries].fetch("mobile")
      response = as(tenant, :employee).call(:delete, "/api/v1/timesheet_entry/bulk_action", body: { source: { ids: [discarded.id] } })
      expect_ok!(response, "bulk discard entry #{discarded.id}")
      discarded.discarded = true
      say "#{label}: W2 moved entries #{moved.map(&:id)} to #{tenant[:other_project].name} and discarded entry #{discarded.id}"
    end

    # W4 agent API: a new agent of the employee's, with a key, creates an
    # entry on the business's project.
    def agent(tenant, current)
      agent = Agent.create!(
        company: tenant[:company], user: tenant[:employee_user], default_project: tenant[:project],
        name: "Alternating writers #{current[:number]}", provider: "alternating-writers"
      )
      _key, token = AgentKey.issue_for(agent:, name: "Alternating writers", created_by: tenant[:admin_user])
      current[:agent] = agent
      body = { timesheet_entry: { duration_minutes: 25, work_date: Date.current.iso8601, note: note_for(tenant, current, "agent") } }
      response = @client.call(:post, "/api/v1/agent/timesheet_entries", body:, headers: { "Authorization" => "Bearer #{token}" })
      expect_ok!(response, "create an entry with W4 agent #{agent.id}")
      record(tenant, current, "agent", response.json.fetch("entry"))
    end

    # W5 Harvest import: an unbilled and a billed row for the employee, run
    # as the imports:harvest_time_entries task runs it.
    def import(tenant, current)
      notes = { "import" => note_for(tenant, current, "import"), "import billed" => note_for(tenant, current, "import billed") }
      data_import = tenant[:company].data_imports.create!(user: tenant[:admin_user], source: "harvest", dry_run: false)
      data_import.file.attach(io: StringIO.new(import_csv(tenant, notes)), filename: "alternating-writers.csv", content_type: "text/csv")
      Imports::HarvestTimeEntriesImporter.new(data_import).process
      unless data_import.reload.status == "completed" && data_import.imported_rows == 2
        fail! "the W5 import for #{tenant[:name]} did not import both rows: #{data_import.status}, " \
              "#{data_import.imported_rows} imported, #{data_import.row_errors.inspect} #{data_import.error_message}"
      end

      listed = entry_list(tenant).values.index_by { |row| row["note"] }
      notes.each do |writer, note|
        row = listed[note] || fail!("the entry list does not show the imported entry #{note.inspect}")
        record(tenant, current, writer, row.merge("agent_id" => nil))
      end
    end

    def import_csv(tenant, notes)
      employee = tenant[:employee_user]
      CSV.generate do |csv|
        csv << ["Date", "Client", "Project", "Notes", "Hours", "Billable?", "Invoiced?", "First Name", "Last Name"]
        [["import", "0.75", "No"], ["import billed", "1.5", "Yes"]].each do |writer, hours, invoiced|
          csv << [Date.current.iso8601, tenant[:project].client.name, tenant[:project].name, notes.fetch(writer), hours, "Yes", invoiced,
                  employee.first_name, employee.last_name]
        end
      end
    end

    # W6 agent destroy: the previous stage's agent, whose entry the previous
    # stage's draft still holds.
    def destroy_agent(previous, label)
      entry = previous[:entries].fetch("agent")
      Agent.find(previous[:agent].id).destroy!
      entry.agent_id = nil
      say "#{label}: W6 destroyed agent #{previous[:agent].id}, detaching entry #{entry.id}"
    end

    # W7: the admin deletes the previous stage's draft, which releases its
    # agent entry (F2).
    def release_draft(tenant, previous, label)
      delete(tenant, :admin, "/api/v1/invoices/#{previous[:draft]}", "delete the draft #{previous[:draft]}")
      previous[:entries].fetch("agent").reserved = nil
      say "#{label}: W7 deleted draft #{previous[:draft]}, releasing entry #{previous[:entries].fetch('agent').id}"
    end

    # W7: the admin saves a draft with a direct line for this stage's agent
    # entry.
    def reserve(tenant, current, label)
      entry = current[:entries].fetch("agent")
      rate = eventually("entry #{entry.id} is offered as an invoice candidate") { candidates(tenant)[entry.id] }.fetch("rate")
      number = "AW-#{tenant[:company].id}-#{current[:number]}"
      body = {
        invoice: {
          client_id: tenant[:project].client_id, invoice_number: number, status: "draft",
          issue_date: Date.current.iso8601, due_date: (Date.current + 30).iso8601, currency: tenant[:company].base_currency,
          invoice_line_items_attributes: [
            { name: "Alternating writers", date: Date.current.iso8601, timesheet_entry_id: entry.id, quantity: entry.duration, rate: }
          ]
        }
      }
      response = as(tenant, :admin).call(:post, "/api/v1/invoices", body:)
      expect_ok!(response, "save the draft #{number}")
      current[:draft] = response.json.fetch("id")
      entry.reserved = current[:draft]
      say "#{label}: W7 saved draft #{number}, reserving entry #{entry.id}"
    end

    # --- what the run wrote -----------------------------------------------

    def note_for(tenant, current, writer) = "Alternating #{tenant[:company].id}-#{current[:number]} #{writer}"

    # Records an entry a writer created, from the answer it gave.
    def record(tenant, current, writer, answer)
      expected_source = CREATED_SOURCE.fetch(writer.delete_suffix(" billed"))
      unless answer["source"] == expected_source
        fail! "the #{writer} entry #{answer['id']} was created with source #{answer['source'].inspect}, not #{expected_source}"
      end

      entry = Entry.new(id: answer.fetch("id"), writer:, stage: current[:number], discarded: false, reserved: nil)
      written(entry, answer)
      current[:entries][writer] = entry
      tenant[:entries] << entry
      entry
    end

    # Takes what the entry holds now from a writer's answer.
    def written(entry, answer)
      fail! "a write of entry #{entry.id} answered entry #{answer['id']}" unless answer["id"] == entry.id

      entry.note = answer["note"]
      entry.duration = answer["duration"].to_f
      entry.project_id = answer["project_id"]
      entry.agent_id = answer["agent_id"]
      entry.bill_status = answer["bill_status"]
      entry.source = answer["source"]
      entry
    end

    # --- checks ---------------------------------------------------------

    def check(tenant, label)
      check_owner(tenant, label)
      check_projection(tenant, label)
      check_reservations(tenant, label)
    end

    # Every entry written so far, read through the owner as the admin.
    def check_owner(tenant, label)
      Current.set(user: tenant[:admin_user], company: tenant[:company]) do
        tenant[:entries].each do |entry|
          held = owner_entry(tenant, entry.id)
          if entry.discarded
            fail! "entry #{entry.id} (#{entry.writer}, stage #{entry.stage}) was discarded, but the owner still holds it" if held
          elsif held.nil? || view(held) != entry.expected
            fail! "entry #{entry.id} (#{entry.writer}, stage #{entry.stage}) is not as last written: " \
                  "expected #{entry.expected}, the owner holds #{held && view(held)}"
          end
        end
      end
      say "#{label}: #{tenant[:entries].size} entries read back through the #{Timekeeping::Ownership.current.owner} owner as last written"
    end

    def owner_entry(tenant, id)
      Timekeeping::EntryReads.call(Timekeeping::EntryReads::Find.new(id:, company: tenant[:company], writer: "web"))
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def check_projection(tenant, label)
      eventually("timesheet_entries holds every entry of #{tenant[:name]} as last written") do
        projected = TimesheetEntry.where(id: tenant[:entries].map(&:id)).index_by(&:id)
        tenant[:entries].all? do |entry|
          row = projected[entry.id]
          row.present? && row.discarded? == entry.discarded && (entry.discarded || view(row) == entry.expected)
        end
      end
      say "#{label}: the projection holds the same"
    end

    def check_reservations(tenant, label)
      reserved, offered = tenant[:entries].reject(&:discarded).partition(&:reserved)
      offered = offered.select { |entry| entry.bill_status == "unbilled" }
      eventually("the candidates leave out the reserved entries #{reserved.map(&:id)} and offer #{offered.map(&:id)}") do
        listed = candidates(tenant).keys
        reserved.none? { |entry| listed.include?(entry.id) } && offered.all? { |entry| listed.include?(entry.id) }
      end
      say "#{label}: the candidates leave out #{reserved.size} reserved entries and offer #{offered.size}"
    end

    def view(record)
      {
        note: record.note.to_s, duration: record.duration.to_d.round(5), project_id: record.project_id, agent_id: record.agent_id,
        bill_status: record.bill_status.to_s, source: record.source
      }
    end

    # --- the CLI and MCP --------------------------------------------------

    # A CLI session's token for the employee, from signing in as the CLI does.
    def cli_token(tenant)
      email = tenant.fetch(:employee)
      @cli_tokens[email] ||= begin
        response = @client.call(:post, "/api/v1/users/login", body: { app: "miru-cli", user: { email:, password: @password } })
        expect_ok!(response, "sign in to the CLI as #{email}")
        response.json.dig("cli_session", "token") || fail!("signing in to the CLI as #{email} answered no token")
      end
    end

    def cli_call(tenant, verb, path, body)
      @client.call(verb, path, body:, headers: { "Authorization" => "Bearer #{cli_token(tenant)}" })
    end

    # Calls an MCP tool over /mcp with the employee's CLI token, and answers
    # the entry the API it proxies answered.
    def mcp_tool(tenant, name, arguments)
      headers = {
        "Authorization" => "Bearer #{cli_token(tenant)}", "Accept" => "application/json, text/event-stream",
        "MCP-Protocol-Version" => "2025-03-26", "MCP-Method" => "tools/call"
      }
      body = { jsonrpc: "2.0", id: SecureRandom.uuid, method: "tools/call", params: { name:, arguments: } }
      response = @client.call(:post, "/mcp", body:, headers:)
      expect_ok!(response, "call the MCP tool #{name}")
      result = response.json["result"] || fail!("the MCP tool #{name} answered no result: #{response.body.to_s.truncate(500)}")
      answer = JSON.parse(result.fetch("content").first.fetch("text"))
      fail! "the MCP tool #{name} failed: #{answer.to_s.truncate(500)}" if result["isError"] || answer["status"] != 200

      answer.dig("data", "entry")
    end

    def summary(tenants)
      tenants.map do |tenant|
        writers = tenant[:entries].group_by(&:writer).transform_values(&:size).map { |writer, count| "#{count} #{writer}" }.join(", ")
        "#{tenant[:name]}: #{tenant[:entries].size} entries (#{writers})"
      end.join("; ")
    end
end
