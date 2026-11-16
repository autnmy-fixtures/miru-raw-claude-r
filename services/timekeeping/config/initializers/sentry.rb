# frozen_string_literal: true

# Timekeeping reports to Sentry as the existing application does
# (config/initializers/sentry.rb there): the DSN from the process
# environment, and only in production and staging. With no SENTRY_DSN, as in
# the local demo, nothing is sent and the alerts are read from the log
# (Signals).
#
# Every event carries the application it came from (docs/architecture/
# timekeeping-soa.md §11.3: "Both applications report to Sentry with a
# `service` tag"). This one's is `timekeeping`; the existing application's is
# `miru`.
Sentry.init do |config|
  config.dsn = ENV["SENTRY_DSN"]
  config.breadcrumbs_logger = [:active_support_logger, :http_logger]
  config.traces_sample_rate = 1.0

  # Alerts are reported through Rails.error (Signals), which sentry-rails
  # 5.17 does not receive unless asked to.
  config.rails.register_error_subscriber = true

  config.environment = Rails.env
  config.enabled_environments = %w[production staging]

  tag_service = ->(event, _hint) { event.tap { event.tags = event.tags.merge(service: "timekeeping") } }
  config.before_send = tag_service
  config.before_send_transaction = tag_service
end
