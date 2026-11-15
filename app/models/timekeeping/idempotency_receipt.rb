# frozen_string_literal: true

# One entry API idempotency receipt of the prepared application
# (docs/architecture/timekeeping-soa.md §9.4): the answer a mutating call
# gave, under its tenant and Idempotency-Key, with the digest of the request
# it answered. Receipts travel in a handoff's checkpoint (§10.5 step 4), so a
# client retry after a rollback returns its stored result.
class Timekeeping::IdempotencyReceipt < ApplicationRecord
  self.table_name = "timekeeping_idempotency_receipts"

  # The stored answer as [status, body], when `digest` is the request it
  # answered; nil for another request under the same key.
  def replay(digest)
    [status, response] if request_digest == digest
  end
end
