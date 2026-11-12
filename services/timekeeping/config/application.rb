# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
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
  end
end
