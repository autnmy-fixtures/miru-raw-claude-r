# frozen_string_literal: true

# The `monolith` owner of the gateway (docs/architecture/timekeeping-soa.md
# §3.1, §10.5): the prepared existing application, which owns the entries
# after a rollback. Entry writes go to local entry code, over its own
# authoritative table, timekeeping_entries (Timekeeping::Entry). It runs the
# single-entry commands of W1 web and mobile, W3 CLI (and so W3a MCP) and W4
# agent, W2's bulk move and bulk discard, W5's import batches and W6's agent
# detach; the gateway refuses W7's invoice callbacks under this owner, which
# the invoice reservation boundary replaces (§7).
#
# The rules are today's, run by today's code: each command builds the
# TimesheetEntry its legacy handler would save, in the same order, and asks
# it whether it is valid. That record is never saved. What it decided, its
# normalized values included, is copied onto the Timekeeping::Entry, which is
# saved as its next version with its audit and outbox rows
# (Timekeeping::LocalEntryChange). The record's `locked` is the entry's
# reservations' (§7.1), so the edit lock stops employees only, as today (L1).
# A model refusal raises today's ActiveRecord::RecordInvalid on that record,
# so the controller answers it with today's public error JSON.
#
# An update or discard holds the entry FOR UPDATE in the command's company
# (§6.3, §9.4), so it serializes with reservation changes
# (Timekeeping::LocalReservations), and checks the caller again on the entry
# as held, with today's TimesheetEntryPolicy (A3-A5, §6.2): an entry billed
# or moved out of the edit window after the controller's own check is still
# refused. An entry this owner does not hold, kept, in the company, is
# today's not-found.
#
# W2's bulk move and bulk discard hold the kept entries they name in the
# command's company FOR UPDATE, in id order, so two bulk commands over the
# same entries cannot deadlock; an id of another company, a discarded entry
# or a missing one is left out, as it is left out of the caller's selection
# today. A9's lock is checked again on the entries as held, as Timekeeping's
# EntryBulk checks it: one billed entry, or one outside the edit window for
# anyone but an owner or admin, refuses the whole command as Locked, with
# nothing written. Then each entry is changed on its own, as today's
# relation `update` and `discard_all` change each record on its own. A move
# runs today's update rules on each entry's rules record; an entry they
# reject is skipped and still answered, as it stands, never refused (A9's
# silent skip, K12). A discard runs no rule, as today's discard runs none.
#
# W6's agent detach is what `dependent: :nullify` did (K8), as Timekeeping's
# EntryDetach does it: every entry of the agent's company that names the
# agent, discarded ones included, is held FOR UPDATE in id order and has its
# agent_id nulled as its next version, with no rule run and no role read, as
# update_all runs none, and updated_at kept, as update_all keeps it. Another
# company's entry is never reached (§6.2, §6.3). It answers the ids it
# detached. The agent row is deleted by the destroy that sent the command,
# in the same transaction, so the destroy and the detach commit together or
# not at all (§3.4).
#
# W5's import batch is today's importer loop, as Timekeeping's EntryImport
# runs it: every row's project is in the importing company, or the whole
# batch is refused with nothing written (§6.3). Each row is decided by
# today's create rules on its own record; a row they reject is never
# written and fails alone, answered by its index with today's message, and
# the rest of the batch is kept, as the savepoint per row keeps it today. A
# billed row is created unbilled and then marked billed (§1.3). The writer
# is always `import`, and the caller the system actor when no user is
# signed in, as in the import job (§6.1). There is no transport to retry
# under this owner, so the batch, one transaction in the fence, writes no
# idempotency receipt, as no other command of this owner does.
#
# The whole command runs inside the gateway's fence transaction (§10.1), so
# the entry, its audit row and its outbox row commit together, under the
# admitted generation. Nothing is written to timesheet_entries here: it stays
# the projection, written only by the projection consumer, which
# Timekeeping::LocalRelay feeds from the outbox (§3.2, §3.3).
module Timekeeping::Gateway::Local
  gateway = Timekeeping::Gateway

  # The entry's columns a writer's rules decide: every field of the
  # contract's entry (common.json#/$defs/entry_fields) apart from the
  # timestamps the owner keeps itself and the derived `locked` (§7.1).
  WRITTEN = (Timekeeping::StoredEntries::FIELDS - %w[created_at updated_at locked]).freeze

  # The columns `audited` records on TimesheetEntry today, so an entry audit
  # row records the same changes as Timekeeping's EntryAudit (§3.4).
  AUDITED = TimesheetEntry.audited_options.fetch(:only).map(&:to_s).freeze

  # The legacy owner sets the command's project and user after the writer's
  # attributes on create, and the project before them on update; the rules
  # record follows that order. A discard runs no rule: today's discard!
  # writes discarded_at with update_attribute, which validates nothing, so
  # an employee may discard their own locked entry, as today.
  HANDLERS = {
    gateway::CreateEntry => ->(command) {
      record = TimesheetEntry.new(command.attributes)
      record.project = command.project
      record.user = command.user
      company = command.project.client.company
      entry = Timekeeping::Entry.new(decided(record).merge(company_id: company.id))
      entry.save!
      Timekeeping::LocalEntryChange.record!(
        entry, action: "create", audited_changes: entry.to_contract.slice(*AUDITED),
        claims: claims(writer: command.writer, company:, project: command.project, agent: command.attributes[:agent])
      )
      answer(entry).tap { |created| Rails.event.notify(TimesheetEntries::Created.new(created)) }
    },
    gateway::UpdateEntry => ->(command) {
      company = command.project.client.company
      held(command.entry.id, company, query: :update?) do |entry, record|
        record.project = command.project
        record.assign_attributes(command.attributes)
        entry.assign_attributes(decided(record))
        saved(entry, claims(writer: command.writer, company:, project: command.project))
      end
    },
    gateway::DiscardEntry => ->(command) {
      project = command.entry.project
      company = project.client.company
      held(command.entry.id, company, query: :destroy?) do |entry|
        entry.discarded_at = Time.current
        saved(entry, claims(writer: command.writer, company:, project:))
      end
    },
    gateway::BulkMove => ->(command) {
      project = command.project
      company = project.client.company
      claims = claims(writer: "bulk", company:, project:)
      bulk_held(command.entries, company, claims).map do |entry|
        record = rules_record(entry)
        record.project_id = project.id
        next answer(entry) unless record.valid?

        entry.assign_attributes(record.attributes.slice(*WRITTEN))
        saved(entry, claims)
      end
    },
    gateway::BulkDiscard => ->(command) {
      claims = claims(writer: "bulk", company: command.company, project: nil)
      bulk_held(command.entries, command.company, claims).map do |entry|
        entry.discarded_at = Time.current
        saved(entry, claims)
        entry.id
      end
    },
    gateway::DetachAgent => ->(command) {
      agent = command.agent
      claims = claims(writer: "agent_destroy", company: agent.company, project: nil)
      Timekeeping::Entry.of_company(agent.company_id).where(agent_id: agent.id).order(:id).lock.includes(:reservations).map do |entry|
        entry.agent_id = nil
        changed!(entry, claims, touch: false)
        entry.id
      end
    },
    gateway::ImportBatch => ->(command) {
      company = command.company
      claims = claims(writer: "import", company:, project: nil)
      foreign!(command.rows.map { |row| row.fetch(:project) }, company)
      created_ids = []
      row_errors = {}
      command.rows.each_with_index do |row, index|
        billed = row.fetch(:bill_status).to_s == "billed"
        record = import_record(row, company, billed:)
        next row_errors[index] = record.errors.full_messages.to_sentence unless record.valid?

        created_ids << imported!(record, company, claims, billed:).id
      end
      gateway::ImportBatch::Result.new(created_ids:, row_errors:)
    }
  }.freeze

  # The roles A9 lets past the edit window, as BulkActionController#entry_locked?
  # and Timekeeping's EntryPolicy treat them.
  PRIVILEGED = %w[owner admin].freeze

  def self.handles?(command) = HANDLERS.key?(command.class)

  # The fence already admitted the command; this owner writes under it.
  def self.call(command, _ownership)
    HANDLERS.fetch(command.class).call(command)
  end

  # What the rules decided for `record`, as the entry's columns: its values
  # after today's normalization, or today's RecordInvalid when it is refused.
  def self.decided(record)
    raise ActiveRecord::RecordInvalid, record unless record.valid?

    record.attributes.slice(*WRITTEN)
  end
  private_class_method :decided

  # W5 refuses the whole batch, with nothing written, when a row names a
  # project of another company (§6.3), as Timekeeping refuses a project its
  # token does not name. The importer only names its company's projects.
  def self.foreign!(projects, company)
    foreign = projects.uniq.reject { |project| project.client.company_id == company.id }
    return if foreign.empty?

    raise Timekeeping::Gateway::Refused.new(
      status: 403, message: "project #{foreign.map(&:id).join(', ')} is not in company #{company.id}"
    )
  end
  private_class_method :foreign!

  # One Harvest row as today's importer creates it (Legacy's import_row):
  # its attributes, its project and user included, in the importing
  # company, and unbilled when the row is billed, because the model refuses
  # to create a billed entry (§1.3). It is never saved.
  def self.import_record(row, company, billed:)
    TimesheetEntry.new(row.merge(bill_status: billed ? "unbilled" : row.fetch(:bill_status))).tap do |record|
      record.association(:company).target = company
    end
  end
  private_class_method :import_record

  # Writes the row its rules accepted as a new entry, version 1, with its
  # create audit and its snapshot, and tells today's listeners it was
  # created, as today's after_create does for each imported row. A billed
  # row is then marked billed as its next version, as today's create! then
  # update! does: an update audit row and a second snapshot. The mark runs
  # no rule, as Timekeeping's EntryImport runs none: the update rules check
  # the values the create just accepted, and the edit lock cannot hold an
  # entry no reservation names yet.
  def self.imported!(record, company, claims, billed:)
    entry = Timekeeping::Entry.create!(record.attributes.slice(*WRITTEN).merge(company_id: company.id))
    Timekeeping::LocalEntryChange.record!(entry, action: "create", audited_changes: entry.to_contract.slice(*AUDITED), claims:)
    Rails.event.notify(TimesheetEntries::Created.new(answer(entry)))
    return entry unless billed

    entry.bill_status = "billed"
    changed!(entry, claims)
    entry
  end
  private_class_method :imported!

  # Holds the kept entries of `company` among `entries` (the caller's
  # selection) FOR UPDATE, in id order, and answers them once none is
  # locked against the caller (A9); otherwise refuses the whole command.
  def self.bulk_held(entries, company, claims)
    held = Timekeeping::Entry.of_company(company.id).kept.where(id: entries.map(&:id)).order(:id).lock.includes(:reservations).to_a
    locked = held.find { |entry| bulk_locked?(entry, claims) }
    raise Timekeeping::Gateway::Locked.new(status: 403, message: "entry #{locked.id} is locked against the caller (A9)") if locked

    held
  end
  private_class_method :bulk_held

  # BulkActionController#entry_locked?, on the entry as held, with the
  # caller's role and the company's edit window from the claims (§6.1).
  def self.bulk_locked?(entry, claims)
    return true if entry.bill_status == "billed"
    return false if PRIVILEGED.include?(claims.fetch("role"))

    entry.work_date < claims.fetch("timesheet_edit_days").days.ago.to_date
  end
  private_class_method :bulk_locked?

  # Holds the kept entry `id` of `company` FOR UPDATE and yields it, with the
  # rules record of the entry as held, once the caller may make `query` of it
  # (TimesheetEntryPolicy). Answers what the block answers.
  def self.held(id, company, query:)
    entry = Timekeeping::Entry.of_company(company.id).kept.lock.find_by(id:)
    raise ActiveRecord::RecordNotFound.new("Couldn't find TimesheetEntry with 'id'=#{id}", TimesheetEntry.name, "id", id) unless entry

    record = rules_record(entry)
    policy = TimesheetEntryPolicy.new(Current.user, record)
    raise Pundit::NotAuthorizedError.new(query:, record:, policy:) unless Current.user && policy.public_send(query)

    yield entry, record
  end
  private_class_method :held

  # The entry as today's model holds a persisted row: each column in its
  # stored form, `locked` from the entry's reservations (§7.1). It is never
  # saved, and nothing marks it changed until the command changes it.
  def self.rules_record(entry)
    values = entry.attributes.slice(*TimesheetEntry.column_names).merge("locked" => entry.locked?)
    TimesheetEntry.instantiate(values.to_h { |name, value| [name, TimesheetEntry.type_for_attribute(name).serialize(value)] })
      .tap(&:readonly!)
  end
  private_class_method :rules_record

  # Saves the change made to the held `entry` as its next version, with its
  # audit and outbox rows, and answers the entry.
  def self.saved(entry, claims)
    changed!(entry, claims)
    answer(entry)
  end
  private_class_method :saved

  # Saves the change made to the held `entry` as its next version, with its
  # audit and outbox rows. A change that changes nothing writes nothing, as
  # an update with no changes saves nothing today. `touch: false` keeps
  # updated_at, for a change that today's code makes with update_all.
  def self.changed!(entry, claims, touch: true)
    return unless entry.changed?

    entry.version += 1
    entry.save!(touch:)
    Timekeeping::LocalEntryChange.record!(entry, action: "update", audited_changes: entry.audited_update_changes(AUDITED), claims:)
  end
  private_class_method :changed!

  # The entry as written, for rendering only, as the timekeeping owner
  # answers Timekeeping's entry: a read-only TimesheetEntry, never saved.
  def self.answer(entry)
    entry.reservations.reset
    Timekeeping::Gateway::Remote.record(entry.to_contract)
  end
  private_class_method :answer

  # The caller of the command (§6.1), as the timekeeping owner signs it:
  # Current.user, or the system actor when there is none. The audit row
  # names who made the change, the acting agent and the writer from it; W2
  # is always the bulk writer, and W6 the agent_destroy writer.
  def self.claims(writer:, company:, project:, agent: nil)
    Timekeeping::UserToken.caller_claims(
      user: Current.user, company:, writer:, project:, agent:,
      request_id: Rails.event.context[:request_id] || SecureRandom.uuid
    )
  end
  private_class_method :claims
end
