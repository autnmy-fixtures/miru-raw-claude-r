# frozen_string_literal: true

Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]

  # Set traces_sample_rate to 1.0 to capture 100%
  # of transactions for performance monitoring.
  # We recommend adjusting this value in production.
  config.traces_sample_rate = 1.0

  config.environment = Rails.env
  config.enabled_environments = %w[production staging]

  # config.rails.register_error_subscriber is left unset on purpose, unlike in
  # Timekeeping: setting it would send every Rails.error.report in this
  # application to Sentry in production. So the Timekeeping alerts
  # (Timekeeping::Signals) reach the log here, not Sentry.

  # Every event carries the application it came from, as Timekeeping's carry
  # theirs (docs/architecture/timekeeping-soa.md §11.3: "Both applications
  # report to Sentry with a `service` tag").
  tag_service = ->(event, _hint) { event.tap { event.tags = event.tags.merge(service: "miru") } }
  config.before_send = tag_service
  config.before_send_transaction = tag_service
end
