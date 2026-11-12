# frozen_string_literal: true

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = ENV["CI"].present?
  config.consider_all_requests_local = false
  # Rescuable errors (routing, parse, not found) render through the exceptions
  # app, as in production, so the specs see the problem bodies clients see.
  config.action_dispatch.show_exceptions = :rescuable
  config.active_support.deprecation = :stderr
  config.active_record.maintain_test_schema = true
end
