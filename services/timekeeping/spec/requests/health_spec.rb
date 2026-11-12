# frozen_string_literal: true

RSpec.describe "Health" do
  it "answers 200 once the application has booted" do
    get "/up"

    expect(response).to have_http_status(:ok)
  end
end
