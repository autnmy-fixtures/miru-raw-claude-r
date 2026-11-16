# frozen_string_literal: true

require "rails_helper"

# docs/architecture/timekeeping-soa.md §11.3: "Both applications report to
# Sentry with a `service` tag." This one's is `miru`.
RSpec.describe "Sentry service tag" do
  let(:configuration) { Sentry.configuration }

  it "tags every error event with the existing application's service, keeping its own tags" do
    event = Sentry::Event.new(configuration:).tap { |built| built.tags = { "signal" => "relay_lag" } }

    expect(configuration.before_send.call(event, {}).tags).to eq("signal" => "relay_lag", service: "miru")
  end

  it "tags every transaction event the same way" do
    event = Sentry::TransactionEvent.new(configuration:, transaction: Sentry::Transaction.new(hub: Sentry.get_current_hub))

    expect(configuration.before_send_transaction.call(event, {}).tags).to include(service: "miru")
  end
end
