# frozen_string_literal: true

# One time entry in the prepared application's own entry table
# (docs/architecture/timekeeping-soa.md §3.1, §3.2, §10.5): the authoritative
# row the `monolith` owner writes after a rollback, while timesheet_entries
# stays the projection. It is the row Timekeeping keeps, column for column,
# so a checkpoint carries it between the two owners unchanged.
#
# The gateway's `monolith` owner (Timekeeping::Gateway::Local) writes it; no
# ownership record names that owner until a rollback. Nothing here runs a
# writer's rule: the owner runs today's rules before it saves, and a row a
# checkpoint carries is copied as it is (§8 item 1).
class Timekeeping::Entry < ApplicationRecord
  self.table_name = "timekeeping_entries"

  has_many :reservations, class_name: "Timekeeping::Reservation", inverse_of: false, dependent: :restrict_with_exception
  has_many :audits, class_name: "Timekeeping::EntryAudit", inverse_of: :entry, dependent: :restrict_with_exception
  has_many :outbox_snapshots, class_name: "Timekeeping::OutboxSnapshot", inverse_of: :entry, dependent: :restrict_with_exception

  scope :of_company, ->(company_id) { where(company_id:) }
  scope :kept, -> { where(discarded_at: nil) }

  # The fields a prepare answers for each entry of the desired set
  # (reservation_api.json#/$defs/prepared_entry), read from the contract
  # itself.
  PREPARED_FIELDS = Timekeeping::Contracts.document(:reservation_api)
    .dig("$defs", "prepared_entry", "properties").keys.freeze

  # The columns of one contract entry (common.json#/$defs/entry), as a row
  # takes them: every field but the derived `locked`, which is the
  # reservations' to say (§7.1). Active Record casts the carried strings.
  def self.row_for(entry)
    entry.except("locked")
  end

  # The full entry every entry API response carries
  # (common.json#/$defs/entry), rendered as Timekeeping::StoredEntries
  # renders a timesheet_entries row. Preload `reservations`, or each entry
  # reads its own.
  def to_contract
    { "id" => id, "company_id" => company_id, "version" => version }
      .merge(Timekeeping::StoredEntries::FIELDS.index_with { |field| contract_value(field) })
  end

  # The entry's prepare facts in contract form, as Timekeeping's
  # ReservationProtocol renders them: the value the `timekeeping` owner's
  # reservation client answers for the same entry (L8).
  def to_prepared
    Timekeeping::ReservationClient::PreparedEntry.new(**PREPARED_FIELDS.to_h { |field| [field.to_sym, contract_value(field)] })
  end

  # What `audited` records for the update just saved: each of `columns` it
  # changed, as [before, after] in contract form (§3.4), as Timekeeping's
  # Entry#audited_update_changes records it.
  def audited_update_changes(columns)
    saved_changes.slice(*columns).to_h do |field, values|
      [field, values.map { |value| Timekeeping::StoredEntries::FORMATS.fetch(field, :itself.to_proc).call(value) }]
    end
  end

  # True exactly when the entry holds a reservation with the edit lock
  # (§7.1), as the shared rule decides it.
  def locked?
    TimekeepingReservations.locked?(id, reservations.map(&:to_value))
  end

  private

    def contract_value(field)
      return locked? if field == "locked"

      Timekeeping::StoredEntries::FORMATS.fetch(field, :itself.to_proc).call(public_send(field))
    end
end
