# frozen_string_literal: true

# The live contract check of the independent-deployment proof
# (docs/architecture/timekeeping-soa.md §13 item 4, §11.2), which
# bin/timekeeping-demo independent-deploys runs before the two deploys and
# after each one. The contract tests of §12.3 prove each application against
# the shared schemas at the revision it is built from, in its own CI. This
# proves that the two running artifacts still keep those contracts with each
# other, whichever one was just rebuilt and restarted.
#
# It runs while Timekeeping owns the entries with admission open, on this
# application's copy of the ownership record and on Timekeeping's: only then
# does every contract cross between the two applications. On each seeded
# business, over the public API as its users (Timekeeping::PublicApi), it
# drives every contract, through every process of the demo:
#
#   handoff API      read_handoff: Timekeeping's copy holds the same
#                    generation, owner and state as this one (miru-web to
#                    timekeeping-web)
#   entry API        the employee creates an entry, edits it and lists it, and
#                    the admin's invoice candidates offer it; at the end the
#                    employee discards it
#   reservation API  the admin saves a draft with a direct line for it
#                    (prepare from miru-web, commit from the invoice operation
#                    worker in miru-jobs) and the candidates leave it out;
#                    the admin deletes the draft (a discard, which releases
#                    it, F2) and the candidates offer it again
#   entry snapshot   the time-entries report, which reads the projection,
#                    shows the entry as last written, then stops showing it
#                    once it is discarded (Timekeeping's relay, in
#                    timekeeping-relay, to miru-web)
#
# This application's clients check what Timekeeping answers against its
# contract, and Timekeeping checks what it is sent against the same
# documents, so a break on either side fails a write and the check. Each run
# leaves, per business, one discarded entry and one discarded draft, and
# nothing reserved. Any check that does not hold raises Failed.
class Timekeeping::ContractCheck
  include Timekeeping::PublicApi

  class Failed < StandardError; end

  Entry = Struct.new(:id, :duration, :note, keyword_init: true)

  # What a run may change: wait is how long, in seconds, a check waits on a
  # worker; tenants default to the seeded businesses.
  Options = Data.define(:wait, :tenants) do
    def initialize(wait: DEFAULT_WAIT, tenants: TENANTS) = super
  end

  # handoff_client: reads Timekeeping's copy of the ownership record over the
  # handoff API.
  def initialize(client:, password:, handoff_client: Timekeeping::HandoffClient.new, logger: Rails.logger, options: Options.new)
    @client = client
    @password = password
    @handoff_client = handoff_client
    @logger = logger
    @options = options
    @sessions = {}
  end

  def call
    ownership = ensure_timekeeping_owns!
    check_handoff_api(ownership)
    run = SecureRandom.hex(3)
    tenants = @options.tenants
    tenants.each { |tenant| check_tenant(prepare_tenant(tenant), run) }
    say "every contract held between the two running applications, on #{tenants.size} businesses, " \
        "at generation #{ownership.generation}"
    ownership
  end

  private

    def log_prefix = "contract check"

    def wait = @options.wait

    def ensure_timekeeping_owns!
      ownership = Timekeeping::Ownership.current
      return ownership if ownership.owner == "timekeeping" && ownership.state_open?

      fail! "the contract check runs while Timekeeping owns the entries with admission open " \
            "(after the first cutover or a re-cutover); ownership is #{ownership.summary}"
    end

    def check_handoff_api(ownership)
      copy = @handoff_client.status.copy
      expected = { generation: ownership.generation, owner: ownership.owner, state: ownership.state }
      unless copy.to_h == expected
        fail! "Timekeeping's copy of the ownership record is #{copy.to_h}, this application's #{expected}"
      end

      say "handoff API: Timekeeping's copy agrees, generation #{copy.generation}, #{copy.owner}, #{copy.state}"
    end

    def check_tenant(tenant, run)
      entry = check_entry_api(tenant, run)
      check_reservation_api(tenant, entry, run)
      check_entry_snapshot(tenant, entry)
    end

    # The entry API's writes and reads; the snapshot of the edit is checked
    # with the reservation, by when the report shows it.
    def check_entry_api(tenant, run)
      entry = create_entry(tenant, duration: 42.5, note: "Contract check #{run} created")
      id = entry.id
      update_entry(tenant, entry, duration: 43.25, note: "Contract check #{run} edited")
      fail! "#{tenant[:name]}: entry #{id} is not listed as last written" unless same?(entry, entry_list(tenant)[id])
      eventually("entry #{id} is offered as an invoice candidate") { candidates(tenant)[id] }
      say "#{tenant[:name]}: entry API: created, edited and listed entry #{id}; the candidates offer it"
      entry
    end

    def check_reservation_api(tenant, entry, run)
      id = entry.id
      draft_id = save_draft(tenant, entry, candidates(tenant).fetch(id).fetch("rate"), number: "CHK-#{tenant[:company].id}-#{run}")
      eventually("the candidates leave out entry #{id}, reserved by draft #{draft_id}") { !candidates(tenant).key?(id) }
      eventually("the time-entries report shows entry #{id} as last written") { same?(entry, time_entries_report(tenant)[id]) }
      delete(tenant, :admin, "/api/v1/invoices/#{draft_id}", "delete the draft #{draft_id}")
      eventually("the candidates offer entry #{id} again") { candidates(tenant).key?(id) }
      say "#{tenant[:name]}: reservation API: draft #{draft_id} reserved entry #{id}, and released it when deleted"
    end

    def check_entry_snapshot(tenant, entry)
      id = entry.id
      delete(tenant, :employee, "/api/v1/timesheet_entry/#{id}", "discard entry #{id}")
      eventually("entry #{id} leaves the entry list and the time-entries report") do
        !entry_list(tenant).key?(id) && !time_entries_report(tenant).key?(id)
      end
      say "#{tenant[:name]}: entry snapshot: the report showed entry #{id} as edited, and dropped it once discarded"
    end

    def create_entry(tenant, duration:, note:)
      response = as(tenant, :employee).call(:post, "/api/v1/timesheet_entry", body: entry_body(tenant, duration:, note:))
      expect_ok!(response, "create an entry for #{tenant[:name]}")
      Entry.new(id: response.json.dig("entry", "id"), duration:, note:)
    end

    def update_entry(tenant, entry, duration:, note:)
      response = as(tenant, :employee).call(:patch, "/api/v1/timesheet_entry/#{entry.id}", body: entry_body(tenant, duration:, note:))
      expect_ok!(response, "edit entry #{entry.id}")
      entry.duration = duration
      entry.note = note
    end

    def save_draft(tenant, entry, rate, number:)
      body = {
        invoice: {
          client_id: tenant[:project].client_id, invoice_number: number, status: "draft",
          issue_date: Date.current.iso8601, due_date: (Date.current + 30).iso8601,
          currency: tenant[:company].base_currency,
          invoice_line_items_attributes: [
            { name: "Contract check", date: Date.current.iso8601, timesheet_entry_id: entry.id, quantity: entry.duration, rate: }
          ]
        }
      }
      response = as(tenant, :admin).call(:post, "/api/v1/invoices", body:)
      expect_ok!(response, "save the draft #{number}")
      response.json.fetch("id")
    end

    # A delete answers 200 with a notice, or 204 with nothing.
    def delete(tenant, role, path, what)
      response = as(tenant, role).call(:delete, path)
      expect_ok!(response, what) unless response.status == 204
    end
end
