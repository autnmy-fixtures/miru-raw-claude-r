# frozen_string_literal: true

# One audit row of the prepared application's entries
# (docs/architecture/timekeeping-soa.md §3.2, §3.4): what one change did to an
# entry, who made it and through which writer, as Timekeeping's EntryAudit
# records it. Rows travel in a handoff's checkpoint (§10.5 step 4).
class Timekeeping::EntryAudit < ApplicationRecord
  self.table_name = "timekeeping_entry_audits"

  belongs_to :entry, class_name: "Timekeeping::Entry", inverse_of: :audits

  enum :action, { create: "create", update: "update" }, prefix: true
end
