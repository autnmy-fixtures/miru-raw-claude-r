# frozen_string_literal: true

# Every timesheet_entries row in the contract's full-entry form
# (common.json#/$defs/entry), exactly as the row stores it: its own `version`
# and `locked`, and `company_id` from project -> client -> company (§6.3).
#
# The legacy checkpoint (Timekeeping::LegacyCheckpoint, §10.5 step 4) starts
# from it, and the projection check of the reconcile
# (Timekeeping::CheckpointReconcile, §10.4) compares it with what Timekeeping
# holds. One rendering, so the two cannot drift apart.
#
# Values are read as stored (§8 item 1): duration stays the float it is,
# timestamps keep their microseconds, and no model callback runs. Discarded
# entries are included. It writes nothing.
module Timekeeping::StoredEntries
  # The entry's fields as common.json#/$defs/entry_fields names them, read
  # from the contract itself.
  FIELDS = Timekeeping::Contracts.document(:common).dig("$defs", "entry_fields", "properties").keys.freeze

  # How each field that is not already JSON is carried, as Timekeeping's
  # Entry::FORMATS carries it: dates as ISO 8601, timestamps in UTC to the
  # microsecond.
  FORMATS = {
    "work_date" => :iso8601.to_proc,
    "discarded_at" => ->(time) { time&.utc&.iso8601(6) },
    "created_at" => ->(time) { time.utc.iso8601(6) },
    "updated_at" => ->(time) { time.utc.iso8601(6) }
  }.freeze

  # Every row, in id order. A row whose project has no company raises
  # KeyError: an entry is never rendered without its tenant.
  def self.all
    company_ids = TimesheetEntry.joins(project: :client).pluck(:id, "clients.company_id").to_h

    TimesheetEntry.order(:id).map do |row|
      { "id" => row.id, "company_id" => company_ids.fetch(row.id), "version" => row.version }
        .merge(FIELDS.index_with { |field| FORMATS.fetch(field, :itself.to_proc).call(row.public_send(field)) })
    end
  end
end
