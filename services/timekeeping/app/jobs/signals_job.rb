# frozen_string_literal: true

# Reads Timekeeping's polled signal of docs/architecture/timekeeping-soa.md
# §11.3, the relay's lag (Signals::POLLED), and reports its alert. It runs on
# the `timekeeping_relay` queue because Timekeeping runs one worker and no
# other (§11.1); a relay that runs but cannot deliver is caught here, and a
# worker that has stopped is not (Signals). The dispatcher schedules it every
# 15 seconds (config/solid_queue.yml), between the relay's runs.
class SignalsJob < ActiveJob::Base
  queue_as :timekeeping_relay

  def perform
    Signals.new.report!
  end
end
