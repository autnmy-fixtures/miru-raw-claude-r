# frozen_string_literal: true

require "rails_helper"

# The projection endpoint of docs/architecture/timekeeping-soa.md §5.4, driven
# by the consumer-side fake of the relay (§12.3): the fake checks each delivery
# against the entry snapshot contract on the way out and each receipt on the
# way back.
RSpec.describe "POST /internal/v1/projection/entry_snapshots" do
  include TimekeepingCharacterization::Helpers

  let(:relay) { TimekeepingContracts::FakeRelay.new }
  let(:tenant_a) { build_tenant }
  let(:tenant_b) { build_tenant }
  let!(:entry) { unbilled_entry(tenant_a, duration: 60.0) }
  let(:config) { Rails.configuration.x.timekeeping }

  around do |example|
    key = config.token_key
    config.token_key = TimekeepingContracts::TEST_TOKEN_KEY
    example.run
  ensure
    config.token_key = key
  end

  def snapshot(tenant = tenant_a, entry_id: entry.id, version: 1, **data)
    relay.snapshot(
      entry_id:, version:, company_id: tenant.company.id, project_id: tenant.project.id, user_id: tenant.employee.id,
      duration: 90.7, work_date: "2026-11-02", **data
    )
  end

  def post_delivery(delivery, headers: {})
    post delivery.path, params: delivery.body, headers: delivery.headers.merge(headers)
  end

  def expect_problem(status, slug)
    expect(response).to have_http_status(status)
    expect(response.media_type).to eq("application/problem+json")
    expect(TimekeepingContracts.valid?(:entry_snapshot, "common.json#/$defs/problem", response.parsed_body)).to be(true)
    expect(response.parsed_body["type"]).to eq(TimekeepingContracts.problem_type(slug))
  end

  def projected
    TimesheetEntry.with_discarded.order(:id).pluck(:id, :version, :duration)
  end

  describe "a delivery from the relay" do
    it "applies the batch and answers the receipt" do
      receipt = relay.deliver(Rails.application, [snapshot(locked: true)])

      expect(receipt).to eq("applied" => 1, "ignored" => 0)
      expect(entry.reload).to have_attributes(version: 1, duration: 90.7, locked: true)
    end

    it "absorbs duplicated and reordered versions" do
      older = snapshot(version: 1, duration: 10.0)
      newer = snapshot(version: 2, duration: 20.0)

      expect(relay.deliver(Rails.application, [older, newer], order: :reversed)).to eq("applied" => 1, "ignored" => 1)
      expect(relay.deliver(Rails.application, [older, newer], order: :duplicated)).to eq("applied" => 0, "ignored" => 4)
      expect(entry.reload).to have_attributes(version: 2, duration: 20.0)
    end

    it "keeps a float duration exact from the wire to the row" do
      relay.deliver(Rails.application, [snapshot(duration: 479.99999)])

      expect(entry.reload.duration).to eq(479.99999)
    end
  end

  describe "authentication" do
    let(:delivery) { relay.delivery([snapshot]) }

    def refused_with(headers)
      expect { post_delivery(delivery, headers:) }.not_to change { projected }
      expect_problem(401, "unauthenticated")
    end

    it "refuses no token" do
      refused_with("Authorization" => "")
    end

    it "refuses a token signed with another key" do
      refused_with("Authorization" => "Bearer #{TimekeepingContracts::FakeRelay.new(token_key: 'other').service_token}")
    end

    it "refuses a user token, which is for Timekeeping, not the projection" do
      refused_with("Authorization" => "Bearer #{TimekeepingContracts.user_token(company_id: tenant_a.company.id)}")
    end

    it "refuses the relay's token for another audience" do
      token = TimekeepingContracts.sign({ "sub" => "service:timekeeping-relay", "aud" => "timekeeping" })

      refused_with("Authorization" => "Bearer #{token}")
    end

    it "refuses a token for another subject" do
      token = TimekeepingContracts.sign({ "sub" => "service:someone-else", "aud" => "projection" })

      refused_with("Authorization" => "Bearer #{token}")
    end

    it "refuses an expired token" do
      token = TimekeepingContracts.sign({ "sub" => "service:timekeeping-relay", "aud" => "projection" }, now: 2.minutes.ago)

      refused_with("Authorization" => "Bearer #{token}")
    end

    it "refuses every token when no key is configured" do
      config.token_key = nil

      refused_with({})
    end
  end

  describe "the contract" do
    def refused(body:, headers: relay.delivery([snapshot]).headers)
      expect { post TimekeepingContracts.operation(:deliver_snapshots).path, params: body, headers: }.not_to change { projected }
      expect_problem(400, "invalid-request")
    end

    it "refuses a snapshot that breaks the contract" do
      broken = snapshot.deep_merge("data" => { "duration" => "90.7" })

      refused(body: JSON.generate("snapshots" => [broken]))
      expect(response.parsed_body["detail"]).to include("duration")
    end

    it "refuses an empty batch and a body that is not JSON" do
      refused(body: JSON.generate("snapshots" => []))
      refused(body: "{not json")
    end

    it "refuses a delivery without a request id" do
      refused(body: relay.delivery([snapshot]).body, headers: relay.delivery([snapshot]).headers.except("X-Request-Id"))
      expect(response.parsed_body["detail"]).to include("X-Request-Id")
    end
  end

  # §6.3: neither seeded business can project into the other's entries.
  describe "tenant isolation" do
    let!(:entry_b) { unbilled_entry(tenant_b, duration: 60.0) }

    it "refuses the whole batch when one snapshot names another company's row" do
      batch = [snapshot(version: 1, duration: 5.0), snapshot(entry_id: entry_b.id)]

      expect { post_delivery(relay.delivery(batch)) }.not_to change { projected }
      expect_problem(403, "forbidden")
      expect(response.parsed_body["detail"]).to include(entry_b.id.to_s)
    end

    it "projects each tenant's own entries" do
      receipt = relay.deliver(Rails.application, [snapshot(version: 1), snapshot(tenant_b, entry_id: entry_b.id, version: 1)])

      expect(receipt).to eq("applied" => 2, "ignored" => 0)
    end
  end
end
