# frozen_string_literal: true

# Reads the relay lag of docs/architecture/timekeeping-soa.md §11.3 for the
# prepared application's outbox (Timekeeping::Signals::RELAY) and reports its
# alert. It runs on the invoice operation worker's queue, not the relay's, so
# a relay worker that stops is still noticed (§11.1: only the two dedicated
# workers run). The dispatcher schedules it in config/solid_queue.yml.
class Timekeeping::RelaySignalJob < ApplicationJob
  queue_as :invoice_operations

  def perform
    Timekeeping::Signals.new.report!(Timekeeping::Signals::RELAY)
  end
end
