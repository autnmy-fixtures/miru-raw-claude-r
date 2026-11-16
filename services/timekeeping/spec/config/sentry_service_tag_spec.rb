# frozen_string_literal: true

require "rails_helper"

# docs/architecture/timekeeping-soa.md §11.3: "Both applications report to
# Sentry with a `service` tag." This one's is `timekeeping`.
RSpec.describe "Sentry service tag" do
  let(:configuration) { Sentry.configuration }

  it "tags every error event with Timekeeping's service, keeping its own tags" do
    event = Sentry::Event.new(configuration:).tap { |built| built.tags = { "signal" => "relay_lag" } }

    expect(configuration.before_send.call(event, {}).tags).to eq("signal" => "relay_lag", service: "timekeeping")
  end

  it "tags every transaction event the same way" do
    event = Sentry::TransactionEvent.new(configuration:, transaction: Sentry::Transaction.new(hub: Sentry.get_current_hub))

    expect(configuration.before_send_transaction.call(event, {}).tags).to include(service: "timekeeping")
  end

  it "sends only from production and staging, to the DSN in the environment, as the existing application does" do
    expect(configuration.enabled_environments).to eq(%w[production staging])
    expect(configuration.dsn&.to_s).to eq(ENV["SENTRY_DSN"].presence)
  end

  it "receives what Rails.error reports, so every alert reaches it (sentry-rails 5.17 does not by default)" do
    expect(Rails.error.instance_variable_get(:@subscribers)).to include(an_instance_of(Sentry::Rails::ErrorSubscriber))
  end
end
