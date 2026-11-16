# frozen_string_literal: true

# The end-to-end journey of docs/architecture/timekeeping-soa.md §13 item 1,
# on both tenants, in the local demo (§11.2):
#
#   create and edit entries -> a direct and a grouped draft invoice ->
#   reservations -> reports and PDF -> cutover -> new writes -> rollback ->
#   new writes -> re-cutover
#
# It drives the existing application the way its users do, over its public
# HTTP API as each seeded business's own users (an employee writes entries,
# an admin or owner writes invoices and reads reports). So every write goes
# through the controllers, the write gateway and the invoice reservation
# boundary to whichever owner holds the entries at that point: the legacy
# model code, Timekeeping over its entry and reservation APIs, or the
# prepared application. It runs each handoff with its own runner
# (lib/tasks/timekeeping.rake), exactly as an operator does.
#
# Each stage, on each tenant (STAGES):
#
#   entries       the employee creates an entry and edits it, edits the
#                 entry the previous stage created (written under another
#                 owner), and creates three more
#   drafts        the admin saves a draft with a direct line for one of them
#                 and a draft with a grouped line linking the other two
#   reservations  the invoice candidates leave out the three reserved entries
#                 and still offer the unreserved one
#   reports       the time-entries report shows every entry the stage wrote,
#                 as last written (it reads timesheet_entries, the
#                 projection, so under Timekeeping it waits for the relay)
#   pdf           each draft's PDF downloads
#
# Each handoff, between stages:
#
#   money         the financial snapshot (Timekeeping::FinancialSnapshot,
#                 §13 item 2) taken just before the runner and just after it
#                 must be identical; the runner checks its own too
#   kept          every entry accepted so far, under any owner, reads back
#                 through the owner as last written; every reserved entry is
#                 still left out of the candidates and every unreserved one
#                 still offered; every draft still reads (§13 item 3); and the
#                 reports and PDFs again
#
# It starts only from a freshly seeded demo: the ownership record in its
# initial legacy state, before any handoff (Timekeeping::Ownership#
# handoff_begun?). It does not resume. A handoff that stops leaves its journal
# for its own runner to resume or abort; the journey then fails, and the next
# journey needs a fresh demo. Any check that does not hold raises Failed, and
# the journey stops there.
#
# TENANTS, DEFAULT_WAIT, Client and the public-API plumbing are
# Timekeeping::PublicApi's, which Timekeeping::ContractCheck shares; the
# stages, the fresh-demo check and the handoff with its money check are
# Timekeeping::DemoHandoffs', which Timekeeping::AlternatingWriters shares.
class Timekeeping::Journey
  include Timekeeping::PublicApi
  include Timekeeping::DemoHandoffs

  class Failed < StandardError; end

  # The stages, each under the owner the handoff before it left, and the
  # handoff that ends each one.
  STAGES = Timekeeping::DemoHandoffs::STAGES

  # The journey's own record of what it wrote, per tenant, to check after
  # every handoff.
  Entry = Struct.new(:id, :duration, :note, :reserved, keyword_init: true)
  Draft = Struct.new(:id, :number, :entry_ids, keyword_init: true)

  # What a run may change. pdf: false skips the PDF downloads (they need a
  # browser for the existing application's PDF renderer), and says so; wait
  # is how long, in seconds, a check waits on a worker. tenants and stages
  # default to the seeded businesses and the three handoffs.
  Options = Data.define(:pdf, :wait, :tenants, :stages) do
    def initialize(pdf: true, wait: DEFAULT_WAIT, tenants: TENANTS, stages: STAGES) = super
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
  end

  def call
    ensure_fresh!
    tenants = @options.tenants.map { |tenant| prepare_tenant(tenant) }

    @options.stages.each_with_index do |stage, index|
      say "stage #{index + 1}: under the #{stage[:owner]} owner"
      ensure_owner!(stage[:owner])
      tenants.each { |tenant| run_stage(tenant, index) }
      next unless stage[:handoff]

      hand_off(stage[:handoff])
      tenants.each { |tenant| check_kept(tenant) }
    end

    say "journey complete: #{summary(tenants)}"
    tenants
  end

  private

    def log_prefix = "journey"

    def wait = @options.wait

    def run_stage(tenant, index)
      label = "#{tenant[:name]}, stage #{index + 1}"
      write_entries(tenant, index, label)
      save_drafts(tenant, index, label)
      check_reservations(tenant, label)
      check_reports(tenant, tenant[:entries].last(4), label)
      check_pdfs(tenant[:drafts].last(2), tenant, label)
    end

    # --- writes ---------------------------------------------------------

    def write_entries(tenant, index, label)
      previous = tenant[:entries].find { |entry| entry.note.start_with?("Journey #{index} edited") }
      edited = create_entry(tenant, duration: 90.7, note: "Journey #{index + 1} created")
      update_entry(tenant, edited, duration: 95.25, note: "Journey #{index + 1} edited")
      update_entry(tenant, previous, duration: previous.duration + 1, note: "#{previous.note}, again in stage #{index + 1}") if previous
      3.times { |n| create_entry(tenant, duration: [30.0, 0.1, 479.99999][n], note: "Journey #{index + 1} to bill #{n + 1}") }
      say "#{label}: created and edited entry #{edited.id}#{", edited #{previous.id} again" if previous}, created three to bill"
    end

    def create_entry(tenant, duration:, note:)
      response = as(tenant, :employee).call(:post, "/api/v1/timesheet_entry", body: entry_body(tenant, duration:, note:))
      expect_ok!(response, "create an entry for #{tenant[:name]}")
      entry = Entry.new(id: response.json.dig("entry", "id"), duration:, note:, reserved: false)
      tenant[:entries] << entry
      entry
    end

    def update_entry(tenant, entry, duration:, note:)
      response = as(tenant, :employee).call(:patch, "/api/v1/timesheet_entry/#{entry.id}", body: entry_body(tenant, duration:, note:))
      expect_ok!(response, "edit entry #{entry.id}")
      entry.duration = duration
      entry.note = note
    end

    def save_drafts(tenant, index, label)
      direct, *grouped = tenant[:entries].last(3)
      rate = candidate_rate(tenant, direct.id)

      direct_draft = save_draft(tenant, index, "direct", [direct], [
        { name: "Journey direct", date: Date.current.iso8601, timesheet_entry_id: direct.id, quantity: direct.duration, rate: }
      ])
      grouped_draft = save_draft(tenant, index, "grouped", grouped, [
        { name: "Journey grouped", date: Date.current.iso8601, linked_timesheet_entry_ids: grouped.map(&:id),
          quantity: grouped.sum(&:duration), rate: }
      ])
      say "#{label}: saved direct draft #{direct_draft.number} and grouped draft #{grouped_draft.number}"
    end

    def save_draft(tenant, index, kind, entries, lines)
      number = "JRN-#{tenant[:company].id}-#{index + 1}-#{kind}"
      body = {
        invoice: {
          client_id: tenant[:project].client_id, invoice_number: number, status: "draft",
          issue_date: Date.current.iso8601, due_date: (Date.current + 30).iso8601,
          currency: tenant[:company].base_currency, invoice_line_items_attributes: lines
        }
      }
      response = as(tenant, :admin).call(:post, "/api/v1/invoices", body:)
      expect_ok!(response, "save the #{kind} draft #{number}")
      entries.each { |entry| entry.reserved = true }
      Draft.new(id: response.json.fetch("id"), number:, entry_ids: entries.map(&:id)).tap { |draft| tenant[:drafts] << draft }
    end

    # The rate the invoice editor offers for the entry: its candidate row's.
    def candidate_rate(tenant, entry_id)
      eventually("entry #{entry_id} is offered as an invoice candidate") do
        candidates(tenant)[entry_id]
      end.fetch("rate")
    end

    # --- checks ---------------------------------------------------------

    def check_reservations(tenant, label)
      reserved, unreserved = tenant[:entries].partition(&:reserved)
      eventually("the candidates leave out the reserved entries #{reserved.map(&:id)} " \
                 "and offer the unreserved #{unreserved.map(&:id)}") do
        offered = candidates(tenant).keys
        reserved.none? { |entry| offered.include?(entry.id) } && unreserved.all? { |entry| offered.include?(entry.id) }
      end
      say "#{label}: reservations hold #{reserved.size} entries, #{unreserved.size} stay offered"
    end

    def check_reports(tenant, entries, label)
      eventually("the time-entries report shows entries #{entries.map(&:id)} as last written") do
        reported = time_entries_report(tenant)
        entries.all? { |entry| same?(entry, reported[entry.id]) }
      end
      say "#{label}: the time-entries report shows #{entries.size} entries as last written"
    end

    def check_pdfs(drafts, tenant, label)
      return say("#{label}: PDF downloads skipped (no browser for the PDF renderer)") unless @options.pdf

      drafts.each do |draft|
        response = as(tenant, :admin).call(:get, "/api/v1/invoices/#{draft.id}/download")
        unless response.status == 200 && response.body.start_with?("%PDF")
          fail! "the PDF of #{draft.number} did not download: #{response.status} #{response.content_type}"
        end
      end
      say "#{label}: #{drafts.size} draft PDFs downloaded"
    end

    def check_kept(tenant)
      label = "#{tenant[:name]}, after the handoff"
      listed = entry_list(tenant)
      tenant[:entries].each do |entry|
        fail! "entry #{entry.id} is not as last written: #{listed[entry.id].inspect}" unless same?(entry, listed[entry.id])
      end
      say "#{label}: #{tenant[:entries].size} entries read back as last written"
      check_reservations(tenant, label)
      tenant[:drafts].each do |draft|
        response = as(tenant, :admin).call(:get, "/api/v1/invoices/#{draft.id}")
        expect_ok!(response, "read the draft #{draft.number}")
      end
      say "#{label}: #{tenant[:drafts].size} drafts read"
      check_reports(tenant, tenant[:entries], label)
      check_pdfs(tenant[:drafts], tenant, label)
    end

    def summary(tenants)
      tenants.map { |tenant| "#{tenant[:name]}: #{tenant[:entries].size} entries, #{tenant[:drafts].size} drafts" }.join("; ")
    end
end
