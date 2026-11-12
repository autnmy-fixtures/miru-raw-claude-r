# frozen_string_literal: true

require "jwt"

# User tokens as the existing application's Timekeeping::UserToken signs
# them (§6.1), for request specs. TIMEKEEPING_TOKEN_KEY is set for the suite
# here, as the process environment sets it in the local demo (§11.2).
module UserTokens
  TEST_KEY = "timekeeping-test-token-key"

  def user_token_claims(company_id:, **overrides)
    {
      "sub" => "user:7", "company_id" => company_id, "role" => "owner", "timesheet_edit_days" => 7,
      "actor" => { "type" => "user", "agent_id" => nil }, "writer" => "web", "project" => nil,
      "request_id" => "req-#{company_id}"
    }.merge(overrides.transform_keys(&:to_s))
  end

  def user_token(claims, key: TEST_KEY, now: Time.current, ttl: 60)
    JWT.encode(claims.reverse_merge("aud" => "timekeeping", "iat" => now.to_i, "exp" => now.to_i + ttl), key, "HS256")
  end

  # The headers every entry API call carries (entry_api.json x-headers).
  def entry_api_headers(company_id:, **overrides)
    { "Authorization" => "Bearer #{user_token(user_token_claims(company_id:, **overrides))}", "X-Request-Id" => "req-#{company_id}" }
  end
end

RSpec.configure do |config|
  config.include UserTokens
  config.around(type: :request) do |example|
    key = Rails.configuration.x.timekeeping.token_key
    Rails.configuration.x.timekeeping.token_key = UserTokens::TEST_KEY
    example.run
  ensure
    Rails.configuration.x.timekeeping.token_key = key
  end
end
