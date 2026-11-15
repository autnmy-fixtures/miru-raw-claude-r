# frozen_string_literal: true

# One row of the prepared application's outbox
# (docs/architecture/timekeeping-soa.md §5.4, §10.1): the entry snapshot of
# one version of a `monolith` entry, entry_snapshot.json#/$defs/entry_snapshot
# exactly, as Timekeeping's OutboxSnapshot writes it. The id is its outbox
# position. Written only by Timekeeping::LocalEntryChange, in the change's own
# transaction; marked delivered only by Timekeeping::LocalRelay.
class Timekeeping::OutboxSnapshot < ApplicationRecord
  self.table_name = "timekeeping_outbox_snapshots"

  TYPE = Timekeeping::Contracts.document(:entry_snapshot).dig("$defs", "entry_snapshot", "properties", "type", "const")

  belongs_to :entry, class_name: "Timekeeping::Entry", inverse_of: :outbox_snapshots

  # What the relay still has to deliver, in outbox order.
  scope :undelivered, -> { where(delivered_at: nil).order(:id) }

  # The snapshot of the entry as it stands: its full contract entry, with
  # its identity, tenant and version lifted out of `data`.
  def self.of(entry)
    contract = entry.to_contract
    {
      "type" => TYPE, "entry_id" => entry.id, "version" => entry.version, "company_id" => entry.company_id,
      "data" => contract.except("id", "company_id", "version")
    }
  end
end
