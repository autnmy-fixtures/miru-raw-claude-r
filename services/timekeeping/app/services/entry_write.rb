# frozen_string_literal: true

# One mutating call of the entry API (docs/architecture/timekeeping-soa.md
# §3.4, §9.4, §10.1), in one transaction: admission under the carried
# generation, then either the stored answer of an earlier call with the same
# Idempotency-Key, or the change itself and its receipt. The change writes
# its entry rows, audit rows and outbox rows (EntryChange) in the same
# transaction, so a call is all of them or none.
#
# A call that is refused (a Problem::Raised from admission or from the
# change) rolls everything back and stores no receipt: it changed nothing,
# so its retry is decided afresh.
module EntryWrite
  # Who calls (the token's company), under which generation, with which key,
  # and the digest of what it asks (IdempotencyReceipt.digest).
  Call = Data.define(:company_id, :generation, :key, :digest)

  # Runs the change the block makes, which answers [status, body], once per
  # key, and answers what it answered.
  def self.call(call)
    Entry.transaction do
      Ownership.admit!(call.generation)
      IdempotencyReceipt.lock_key!(call.company_id, call.key)
      receipt = IdempotencyReceipt.find_by(company_id: call.company_id, key: call.key)
      next receipt.replay(call.digest) || conflict!(call) if receipt

      yield.tap do |status, body|
        IdempotencyReceipt.create!(company_id: call.company_id, key: call.key, request_digest: call.digest, status:, response: body)
      end
    end
  end

  def self.conflict!(call)
    raise Problem::Raised, Problem.new(
      slug: "idempotency-conflict", status: 409,
      detail: "Idempotency-Key #{call.key} already answered another request"
    )
  end
  private_class_method :conflict!
end
