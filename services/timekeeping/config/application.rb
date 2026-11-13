# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
require "active_job/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

module Timekeeping
  # Timekeeping (docs/architecture/timekeeping-soa.md §3, §11.1): an API-only
  # application with its own database. It owns time entries and their billing
  # reservations, and serves them only on its internal API (§5).
  class Application < Rails::Application
    config.load_defaults 8.1
    config.api_only = true

    config.autoload_lib(ignore: %w[tasks])

    # Every error answers application/problem+json (§5.1), routing errors and
    # unparseable bodies included, so a client reads any non-2xx answer one way.
    config.exceptions_app = ->(env) { ProblemsController.action(:show).call(env) }

    # Jobs run on this service's own Solid Queue tables, in its own database
    # (§11.1). Only the relay's dedicated worker is configured
    # (config/solid_queue.yml).
    config.active_job.queue_adapter = :solid_queue
  end
end
