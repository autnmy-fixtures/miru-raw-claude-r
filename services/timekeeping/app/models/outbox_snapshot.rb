# frozen_string_literal: true

# One row of the outbox (docs/architecture/timekeeping-soa.md §5.4): the
# entry snapshot of one entry version, entry_snapshot.json#/$defs/entry_snapshot
# exactly, for the relay to deliver. The id is its outbox position. Written
# only by EntryChange, in the change's own transaction.
class OutboxSnapshot < ApplicationRecord
  TYPE = "timekeeping.entry_snapshot.v1"

  belongs_to :entry

  # The snapshot of the entry as it stands: the full entry of the entry API
  # with its identity, tenant and version lifted out of `data`.
  def self.of(entry)
    contract = entry.to_contract
    {
      "type" => TYPE, "entry_id" => entry.id, "version" => entry.version, "company_id" => entry.company_id,
      "data" => contract.except("id", "company_id", "version")
    }
  end
end
