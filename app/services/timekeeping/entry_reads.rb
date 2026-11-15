# frozen_string_literal: true

# The entry API's own reads (docs/architecture/timekeeping-soa.md §3.3 rule
# 1): the list and show a user makes right after writing, read from the
# owner of the entries, never from the projection, which may lag. They are
# the time-tracking list of W1 web and mobile (and so MCP's miru.time.list,
# which reaches it in-process), and the lookup W1 and W3 (and so W3a MCP)
# make before an update or discard, and the selection W2 bulk move and bulk
# discard make of the entries they name, so an entry the relay has not
# projected yet can be edited at once, and is authorized on the owner's
# current state. W5's duplicate check reads the owner too, so a re-run right
# after an import skips the rows the owner already holds, projected or not.
#
# Under `legacy` each read is today's query, moved here unchanged. Under
# `timekeeping` it is the entry API (§5.2), with the caller's claims (§6.1),
# answered as read-only TimesheetEntry records, so callers authorize and
# render them with today's code. Under `monolith`, the prepared application
# after a rollback (§10.5), it is the same read of that owner's own entry
# table (Timekeeping::Entry), answered the same way: the kept entries of the
# company (§6.3), each with the `locked` its reservations derive (§7.1), and
# never a timesheet_entries row.
#
# The caller decided who may read, as today: the policy, the company and,
# for W3, the caller's own entries (A7). W2's selection applies the policy
# scope itself (A6), under every owner, through TimesheetEntryPolicy::Scope.
# W5 runs as the system actor, as its batches do: an import has no
# Current.user (§6.1).
# The owner is read without the generation fence: a read writes nothing, so
# it needs no admission (§10.1).
module Timekeeping::EntryReads
  # The kept entries of `user` in `company` with work dates from `from` to
  # `to`, newest work date first, as today's time-tracking list orders them.
  List = Data.define(:user, :company, :from, :to, :writer)

  # One kept entry of `company` (W1).
  Find = Data.define(:id, :company, :writer)

  # One kept entry of `company` that `user` owns (W3, A7).
  FindOwn = Data.define(:id, :user, :company, :writer)

  # The kept entries among `ids` that `user`'s policy scope admits (W2, A6):
  # every entry of the workspace for an owner or admin, their own for anyone
  # else.
  Select = Data.define(:ids, :user, :company, :writer)

  # What W5's duplicate check compares a row with: of every kept entry an
  # earlier import wrote (source "import") on the kept projects of kept
  # clients among `project_ids`, with work dates in the inclusive Range of
  # Dates `work_dates`, the values of IMPORTED_KEY.
  Imported = Data.define(:company, :project_ids, :work_dates) do
    def writer = "import"
  end

  # The entry values an import's duplicate key is made of, in order.
  IMPORTED_KEY = %i[user_id project_id work_date duration note].freeze

  # What the time-tracking list renders of each entry (TimesheetEntry#snippet).
  LISTED = [:user, :agent, { project: :client }].freeze

  OWNERS = {
    "legacy" => {
      List => ->(read) {
        read.user.timesheet_entries.kept.includes(:user, project: :client)
          .in_workspace(read.company).during(read.from, read.to)
      },
      Find => ->(read) { read.company.timesheet_entries.kept.find(read.id) },
      FindOwn => ->(read) { read.user.timesheet_entries.kept.in_workspace(read.company).find(read.id) },
      Select => ->(read) { policy_scope(read).resolve.where(id: read.ids) },
      Imported => ->(read) {
        TimesheetEntry.kept.joins(project: :client)
          .merge(Project.kept)
          .merge(Client.kept)
          .where(project_id: read.project_ids, work_date: read.work_dates, source: "import")
          .pluck(*IMPORTED_KEY)
      }
    },
    "timekeeping" => {
      List => ->(read) {
        entries = Timekeeping::EntryClient.new.list_entries(
          user_id: read.user.id, work_dates: read.from.to_date..read.to.to_date, claims: claims(read)
        )
        records = entries.map { |entry| Timekeeping::Gateway::Remote.record(entry) }
          .sort_by { |entry| [-entry.work_date.jd, entry.id] }
        ActiveRecord::Associations::Preloader.new(records:, associations: LISTED).call
        records
      },
      Find => ->(read) { owned(read) },
      FindOwn => ->(read) { owned(read).tap { |entry| raise not_found(read) unless entry.user_id == read.user.id } },
      Select => ->(read) {
        Timekeeping::EntryClient.new.list_entries(
          ids: Array(read.ids).filter_map { |id| entry_id(id) },
          user_id: (read.user.id if policy_scope(read).own_entries_only?), claims: claims(read)
        ).map { |entry| Timekeeping::Gateway::Remote.record(entry) }
      },
      # The catalogue stays here, so which projects are kept is decided here,
      # as candidate selection decides it; the owner answers their entries.
      Imported => ->(read) {
        project_ids = Project.kept.joins(:client).merge(Client.kept).where(id: read.project_ids).ids
        Timekeeping::EntryClient.new.list_entries(project_ids:, work_dates: read.work_dates, claims: claims(read))
          .map { |entry| Timekeeping::Gateway::Remote.record(entry) }
          .filter_map { |entry| IMPORTED_KEY.map { |name| entry.public_send(name) } if entry.source == "import" }
      }
    },
    # The same reads as the timekeeping owner's, over the prepared
    # application's own table: the filters Timekeeping's EntryList applies,
    # in the read's company.
    "monolith" => {
      List => ->(read) {
        records = local_records(
          held(read.company).where(user_id: read.user.id, work_date: read.from.to_date..read.to.to_date)
        ).sort_by { |entry| [-entry.work_date.jd, entry.id] }
        ActiveRecord::Associations::Preloader.new(records:, associations: LISTED).call
        records
      },
      Find => ->(read) { held_one(read) },
      FindOwn => ->(read) { held_one(read).tap { |entry| raise not_found(read) unless entry.user_id == read.user.id } },
      Select => ->(read) {
        entries = held(read.company).where(id: Array(read.ids).filter_map { |id| entry_id(id) })
        entries = entries.where(user_id: read.user.id) if policy_scope(read).own_entries_only?
        local_records(entries.order(:id))
      },
      Imported => ->(read) {
        project_ids = Project.kept.joins(:client).merge(Client.kept).where(id: read.project_ids).ids
        local_records(held(read.company).where(project_id: project_ids, work_date: read.work_dates, source: "import"))
          .map { |entry| IMPORTED_KEY.map { |name| entry.public_send(name) } }
      }
    }
  }.freeze

  def self.call(read)
    owner = Timekeeping::Ownership.current.owner
    reads = OWNERS.fetch(owner) do
      raise Timekeeping::Gateway::OwnerUnavailable, "Timekeeping entry reads: owner #{owner} has no entry store yet"
    end
    reads.fetch(read.class).call(read)
  end

  # The owner's entry the read names, or today's not-found. An id that can
  # name no row is not asked for, as today's find answers it.
  def self.owned(read)
    id = entry_id(read.id)
    raise not_found(read) unless id

    Timekeeping::Gateway::Remote.record(Timekeeping::EntryClient.new.show_entry(id, claims: claims(read)))
  rescue Timekeeping::InternalApi::Problem => problem
    raise problem.type == "not-found" ? not_found(read) : problem
  end
  private_class_method :owned

  # The kept entries the `monolith` owner holds for `company` (§6.3).
  def self.held(company) = Timekeeping::Entry.of_company(company.id).kept
  private_class_method :held

  # The `monolith` owner's entry the read names, or today's not-found.
  def self.held_one(read)
    id = entry_id(read.id)
    entry = id && held(read.company).find_by(id:)
    raise not_found(read) unless entry

    local_records([entry]).sole
  end
  private_class_method :held_one

  # Entries of the prepared application's table as the owner's read answers
  # them: each one's contract entry as a read-only TimesheetEntry, with
  # `locked` from its reservations (§7.1), as the timekeeping owner's are.
  def self.local_records(entries)
    entries = entries.to_a
    ActiveRecord::Associations::Preloader.new(records: entries, associations: :reservations).call
    entries.map { |entry| Timekeeping::Gateway::Remote.record(entry.to_contract) }
  end
  private_class_method :local_records

  # The entry id a request param names, or nil when it can name no row.
  def self.entry_id(param)
    id = Integer(param.to_s, 10, exception: false)
    id if id&.positive?
  end
  private_class_method :entry_id

  def self.policy_scope(read) = TimesheetEntryPolicy::Scope.new(read.user, TimesheetEntry)
  private_class_method :policy_scope

  def self.not_found(read)
    ActiveRecord::RecordNotFound.new("Couldn't find TimesheetEntry with 'id'=#{read.id}", TimesheetEntry.name, "id", read.id)
  end
  private_class_method :not_found

  # Current.user is the caller the request authenticated (§6.1).
  def self.claims(read)
    Timekeeping::UserToken.caller_claims(
      user: Current.user, company: read.company, writer: read.writer,
      request_id: Rails.event.context[:request_id] || SecureRandom.uuid
    )
  end
  private_class_method :claims
end
