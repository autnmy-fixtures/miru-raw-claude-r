# frozen_string_literal: true

# The duplicate and reordered delivery of docs/architecture/timekeeping-soa.md
# §13 item 6, sent on purpose (OutboxRedelivery): the named entries' outbox
# snapshots, resent to the projection consumer newest first, then each older
# one alone, then all of them again, through the relay's own delivery:
#
#   bin/rails timekeeping:redeliver ENTRIES="3089 3090"
#
# It prints each batch and the consumer's receipt, and exits 1 at the first
# receipt that is not the one the consumer must answer, or when it refuses to
# send. It marks nothing in the outbox. bin/timekeeping-demo redelivery runs
# it in timekeeping-web while the relay is stopped.
module TimekeepingRedeliveryTask
  def self.entry_ids(value)
    ids = value.to_s.split.map { |id| Integer(id, 10) }
    ids.presence || abort("ENTRIES names the entries to redeliver, by id, separated by spaces")
  rescue ArgumentError
    abort "ENTRIES names entries by id, separated by spaces, and #{value.inspect} does not"
  end

  def self.line(sent)
    receipt = sent.receipt
    "redelivery: #{sent.step}: #{sent.summary}: applied #{receipt.fetch('applied')}, ignored #{receipt.fetch('ignored')}"
  end
end

namespace :timekeeping do
  desc "Resend entries' outbox snapshots out of order and twice; the projection must apply only the newest (docs/architecture/timekeeping-soa.md 13 item 6; ENTRIES)"
  task redeliver: :environment do
    ids = TimekeepingRedeliveryTask.entry_ids(ENV.fetch("ENTRIES", nil))
    sent = OutboxRedelivery.new(entry_ids: ids).call { |batch| puts TimekeepingRedeliveryTask.line(batch) }
    puts "redelivery: #{sent.size} batches of #{ids.size} entries' snapshots resent out of order and twice; " \
         "the consumer applied each entry's newest once and ignored every other"
  rescue OutboxRedelivery::Error, OutboxRelay::Error => error
    abort "redelivery failed: #{error.message}"
  end
end
