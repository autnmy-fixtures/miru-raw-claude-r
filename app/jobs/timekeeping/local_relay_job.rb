# frozen_string_literal: true

# Runs the prepared application's relay (Timekeeping::LocalRelay,
# docs/architecture/timekeeping-soa.md §5.4, §11.1) on its own queue,
# `timekeeping_relay`, which only its dedicated worker reads, so it runs while
# the `default` worker is not started. The dispatcher enqueues it every second
# in config/solid_queue.yml.
#
# A batch the projection did not take stays in the outbox, is reported, and
# the next run applies it again; the job does not raise for it. Stopping the
# worker pauses the relay; the outbox keeps every change until it resumes.
class Timekeeping::LocalRelayJob < ApplicationJob
  queue_as :timekeeping_relay

  def perform
    Timekeeping::LocalRelay.new.run
  end
end
