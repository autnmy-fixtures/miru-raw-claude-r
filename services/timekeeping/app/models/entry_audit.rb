# frozen_string_literal: true

# One entry audit row (docs/architecture/timekeeping-soa.md §3.2, §3.4): what
# one change did to an entry, who made it, and through which writer. Written
# only by EntryChange, in the change's own transaction.
class EntryAudit < ApplicationRecord
  belongs_to :entry

  enum :action, { create: "create", update: "update" }, prefix: true
end
