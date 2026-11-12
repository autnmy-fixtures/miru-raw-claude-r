# frozen_string_literal: true

# One time entry, as Timekeeping owns it (docs/architecture/timekeeping-soa.md
# §3.2): the existing application's timesheet_entries row, with the tenant it
# belongs to (§6.3) and its version (§3.2).
class Entry < ApplicationRecord
  # The entry's fields as common.json#/$defs/entry_fields names them, in
  # order, apart from the derived `locked`.
  FIELDS = %w[
    project_id user_id agent_id duration work_date note bill_status review_status
    source source_metadata proof_url proof_metadata external_run_id external_session_id
    discarded_at created_at updated_at
  ].freeze

  # How each field that is not already JSON is carried (§5.1): dates as ISO
  # 8601, timestamps in UTC to the microsecond. `duration` is the stored
  # float, which JSON writes in Ruby's shortest round-trip form.
  FORMATS = {
    "work_date" => :iso8601.to_proc,
    "discarded_at" => ->(time) { time&.utc&.iso8601(6) },
    "created_at" => ->(time) { time.utc.iso8601(6) },
    "updated_at" => ->(time) { time.utc.iso8601(6) }
  }.freeze

  has_many :reservations, dependent: :restrict_with_exception

  scope :of_company, ->(company_id) { where(company_id:) }
  scope :kept, -> { where(discarded_at: nil) }

  # The full entry every entry API response carries
  # (common.json#/$defs/entry). Preload `reservations`, or each entry reads
  # its own.
  def to_contract
    { "id" => id, "company_id" => company_id, "version" => version }
      .merge(FIELDS.index_with { |field| FORMATS.fetch(field, :itself.to_proc).call(public_send(field)) })
      .merge("locked" => locked?)
  end

  # True exactly when the entry holds a reservation with edit_lock (§7.1),
  # as the shared rule decides it.
  def locked?
    TimekeepingReservations.locked?(id, reservations.map(&:to_value))
  end
end
