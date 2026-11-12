# frozen_string_literal: true

require "rails_helper"

# TimesheetEntry's create rules as Timekeeping runs them (§2.1, §6.2): only in
# a writer's context, and worded as the existing application words them.
RSpec.describe "Entry create rules" do
  def writer_entry(**attributes)
    Entry.new({ company_id: 1, project_id: 11, user_id: 7, duration: 30.0, work_date: Date.new(2026, 11, 2) }.merge(attributes))
      .tap { |entry| entry.project_facts = { "id" => 11, "company_id" => 1, "kept" => true, "billable" => true } }
  end

  it "words each error as the existing application's config/locales/errors.en.yml does" do
    existing = YAML.load_file(Rails.root.join("../../config/locales/errors.en.yml")).dig("en", "errors")
    ours = YAML.load_file(Rails.root.join("config/locales/en.yml")).dig("en", "errors")

    expect(ours).to eq(existing.slice(*ours.keys))
  end

  it "never runs on a row written directly, as a checkpoint loads one (§8 item 1)" do
    entry = entry!(company_id: 1, bill_status: "unbilled", source: "cli", source_metadata: { "mcp_server" => "miru", "other" => "kept" })

    expect(entry.reload).to have_attributes(source: "cli", source_metadata: { "mcp_server" => "miru", "other" => "kept" })
  end

  it "keeps an inferred automation source and an import, and falls back to manual for an unknown one" do
    expect(writer_entry(source_metadata: { "tool" => "timer" }).tap { |entry| entry.valid?(Entry::CREATE) }.source).to eq("automation")
    expect(writer_entry(source: "import").tap { |entry| entry.valid?(Entry::CREATE) }.source).to eq("import")
    expect(writer_entry(source: "fax").tap { |entry| entry.valid?(Entry::CREATE) }.source).to eq("manual")
  end

  it "keeps at most 20 proof metadata keys, false and 0 among them" do
    metadata = { "flag" => false, "count" => 0 }.merge((1..30).to_h { |n| ["k#{n}", "v"] })
    entry = writer_entry(proof_metadata: metadata).tap { |candidate| candidate.valid?(Entry::CREATE) }

    expect(entry.proof_metadata.size).to eq(20)
    expect(entry.proof_metadata).to include("flag" => false, "count" => 0)
  end
end
