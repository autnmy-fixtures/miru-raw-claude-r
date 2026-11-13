# frozen_string_literal: true

# Runs the relay (docs/architecture/timekeeping-soa.md §5.4, §15.1 D3) on its
# own queue, `timekeeping_relay`, which only the relay's dedicated worker
# reads (config/solid_queue.yml). The dispatcher enqueues it every second.
#
# It has no retry of its own: a batch the consumer did not confirm stays in
# the outbox, is reported, and the next run sends it again. Stopping the
# worker pauses the relay; the outbox keeps every change until it resumes.
class OutboxRelayJob < ActiveJob::Base
  queue_as :timekeeping_relay

  def perform
    OutboxRelay.new.run
  end
end
