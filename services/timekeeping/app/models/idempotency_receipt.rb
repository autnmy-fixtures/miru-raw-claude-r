# frozen_string_literal: true

# One entry API idempotency receipt (docs/architecture/timekeeping-soa.md
# §9.4): the answer a mutating call gave, stored under its tenant and
# Idempotency-Key with the digest of the request it answered. Same key and
# same digest replays the answer; same key and another digest is refused.
class IdempotencyReceipt < ApplicationRecord
  # The digest of one request: its method, path and contract-checked body,
  # so the same command sent twice digests the same however its JSON is
  # spaced.
  def self.digest(method, path, body)
    Digest::SHA256.hexdigest([method, path, JSON.generate(body)].join("\n"))
  end

  # Serializes the calls that carry one key in one tenant until the caller's
  # transaction ends, so a retry that overtakes its own first attempt waits
  # for it and then replays its receipt instead of writing twice. The unique
  # index on (company_id, key) is the backstop.
  def self.lock_key!(company_id, key)
    connection.execute(sanitize_sql_array(["SELECT pg_advisory_xact_lock(hashtextextended(?, 0))", "#{company_id}:#{key}"]))
  end

  # The stored answer as [status, body], when `digest` is the request it
  # answered.
  def replay(digest)
    [status, response] if request_digest == digest
  end
end
