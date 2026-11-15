# frozen_string_literal: true

# The `monolith` owner of the gateway (docs/architecture/timekeeping-soa.md
# §3.1, §10.5): the prepared existing application, which owns the entries
# after a rollback. Entry writes go to local entry code, over its own
# authoritative table, timekeeping_entries (Timekeeping::Entry). So far it
# runs the single-entry commands of W1 web and mobile, W3 CLI (and so W3a
# MCP) and W4 agent; the gateway refuses every other command under this
# owner.
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
        claims: claims(command, company:, project: command.project, agent: command.attributes[:agent])
      )
      answer(entry).tap { |created| Rails.event.notify(TimesheetEntries::Created.new(created)) }
    },
    gateway::UpdateEntry => ->(command) {
      company = command.project.client.company
      held(command.entry.id, company, query: :update?) do |entry, record|
        record.project = command.project
        record.assign_attributes(command.attributes)
        entry.assign_attributes(decided(record))
        saved(entry, claims(command, company:, project: command.project))
      end
    },
    gateway::DiscardEntry => ->(command) {
      project = command.entry.project
      company = project.client.company
      held(command.entry.id, company, query: :destroy?) do |entry|
        entry.discarded_at = Time.current
        saved(entry, claims(command, company:, project:))
      end
    }
  }.freeze

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
  # audit and outbox rows, and answers the entry. A change that changes
  # nothing writes nothing, as an update with no changes saves nothing today.
  def self.saved(entry, claims)
    if entry.changed?
      entry.version += 1
      entry.save!
      Timekeeping::LocalEntryChange.record!(entry, action: "update", audited_changes: entry.audited_update_changes(AUDITED), claims:)
    end
    answer(entry)
  end
  private_class_method :saved

  # The entry as written, for rendering only, as the timekeeping owner
  # answers Timekeeping's entry: a read-only TimesheetEntry, never saved.
  def self.answer(entry)
    entry.reservations.reset
    Timekeeping::Gateway::Remote.record(entry.to_contract)
  end
  private_class_method :answer

  # The caller of the command (§6.1), as the timekeeping owner signs it:
  # Current.user, or the system actor when there is none. The audit row
  # names who made the change, the acting agent and the writer from it.
  def self.claims(command, company:, project:, agent: nil)
    Timekeeping::UserToken.caller_claims(
      user: Current.user, company:, writer: command.writer, project:, agent:,
      request_id: Rails.event.context[:request_id] || SecureRandom.uuid
    )
  end
  private_class_method :claims
end
