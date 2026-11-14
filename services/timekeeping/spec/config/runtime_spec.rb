# frozen_string_literal: true

# §11.1 and §11.2: Timekeeping runs on its own database, reads the one shared
# library, and takes its configuration from its own process environment.
RSpec.describe "Timekeeping runtime" do
  it "runs on its own database, which holds none of the existing application's tables" do
    connection = ActiveRecord::Base.connection

    expect(connection.current_database).to eq("timekeeping_test")
    expect(connection.tables).not_to include("timesheet_entries", "invoices", "timekeeping_ownerships")
  end

  it "reads the shared reservation decision table and contracts from packages/" do
    expect(TimekeepingReservations::TABLE).not_to be_empty
    expect(Rails.configuration.x.timekeeping.contracts_dir.glob("*.json").map { |path| path.basename(".json").to_s })
      .to contain_exactly("common", "entry_api", "entry_snapshot", "handoff_api", "reservation_api")
  end

  it "takes the shared token key and the existing application's URL from the environment" do
    expect(Rails.configuration.x.timekeeping.token_key).to eq(ENV["TIMEKEEPING_TOKEN_KEY"])
    expect(Rails.configuration.x.timekeeping.existing_app_url).to eq(ENV["EXISTING_APP_URL"])
  end

  it "answers only the internal API and the health check: no views, no cookies, no sessions" do
    expect(Rails.application.config.api_only).to be(true)
    expect(Rails.application.middleware.map(&:klass)).not_to include(ActionDispatch::Cookies, ActionDispatch::Session::CookieStore)
  end
end
