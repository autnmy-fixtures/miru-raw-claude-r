# frozen_string_literal: true

require "rails_helper"

# Which owner answers the entry API's own reads
# (docs/architecture/timekeeping-soa.md §3.3 rule 1). The reads themselves
# are proven through the real entry points in
# spec/requests/timekeeping/entry_reads_spec.rb.
RSpec.describe Timekeeping::EntryReads do
  include_context "with two Timekeeping tenants"

  let(:employee) { tenant_a.employee }
  let(:entry) { unbilled_entry(tenant_a, work_date: Date.new(2026, 11, 2)) }
  let(:reads) do
    [
      described_class::List.new(user: employee, company: tenant_a.company, from: Date.new(2026, 11, 1), to: Date.new(2026, 11, 30), writer: "web"),
      described_class::Find.new(id: entry.id, company: tenant_a.company, writer: "web"),
      described_class::FindOwn.new(id: entry.id, user: employee, company: tenant_a.company, writer: "cli")
    ]
  end

  it "has a read for every owner with an entry store, and the same reads for each" do
    expect(described_class::OWNERS.keys).to eq(%w[legacy timekeeping])
    expect(described_class::OWNERS.values.map(&:keys)).to all(eq(reads.map(&:class)))
  end

  it "answers today's queries under the legacy owner" do
    list, find, find_own = reads.map { |read| described_class.call(read) }

    expect(list.to_a).to eq([entry])
    expect([find, find_own]).to eq([entry, entry])
    expect { described_class.call(reads[2].with(user: tenant_a.admin)) }.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "refuses every read under the monolith owner, which has no entry store yet" do
    set_timekeeping_ownership!(TimekeepingOwnershipStates::AFTER_HANDOFF_BEGUN.fetch("rolled back to the prepared application"))

    reads.each do |read|
      expect { described_class.call(read) }.to raise_error(Timekeeping::Gateway::OwnerUnavailable, /owner monolith has no entry store yet/)
    end
  end
end
