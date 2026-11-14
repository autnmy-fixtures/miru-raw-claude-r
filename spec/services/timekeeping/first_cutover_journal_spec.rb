# frozen_string_literal: true

require "rails_helper"

# The first cutover's journal (docs/architecture/timekeeping-soa.md §10.5:
# "can resume from the step that failed"): what an interrupted run of the
# handoff tool took, kept in a file so a run in another process resumes it.
# The checkpoint is a real one, taken from the legacy owner on two tenants, so
# every value the load carries round-trips through the file.
RSpec.describe Timekeeping::FirstCutoverJournal, type: :model do
  include_context "with two Timekeeping tenants"

  let(:directory) { Pathname(Dir.mktmpdir("timekeeping-journal")) }
  let(:journal) { described_class.new(path: directory.join("handoff/first_cutover.json")) }

  let!(:draft_entry) { unbilled_entry(tenant_a, duration: 479.99999, note: "präzise", source_metadata: { "tags" => [nil, "x"] }) }
  let!(:linked_entry) { unbilled_entry(tenant_b, duration: 0.1) }
  let!(:discarded_entry) { unbilled_entry(tenant_a).tap(&:discard!) }

  let!(:draft) { invoice_for(tenant_a).tap { |invoice| direct_line(invoice, draft_entry).then { invoice.reload.save! } } }
  let!(:unlocked_link_invoice) { invoice_for(tenant_b, status: :sent).tap { |invoice| direct_line(invoice, linked_entry) } }

  let(:resume) do
    financial_snapshot = Timekeeping::FinancialSnapshot.process
    set_timekeeping_ownership!(generation: 1, owner: "legacy", state: "frozen")
    checkpoint = Timekeeping::LegacyCheckpoint.take(generation: 1, unlocked_link_invoice_ids: [unlocked_link_invoice.id])
    Timekeeping::FirstCutover::Resume.new(financial_snapshot:, checkpoint:)
  end

  after { FileUtils.rm_rf(directory) }

  it "answers an empty resume while nothing is recorded" do
    expect(journal.resume).to eq(Timekeeping::FirstCutover::Resume.new)
    expect(journal.path).not_to exist
  end

  it "reads back exactly the resume it recorded: the financial snapshot, and the checkpoint with every value as taken" do
    journal.record(resume)

    read = described_class.new(path: journal.path).resume

    expect(read).to eq(resume)
    expect(read.checkpoint.entries.map { |entry| entry.fetch("duration") }).to include(479.99999, 0.1)
    expect(read.checkpoint.reservations.map { |reservation| reservation.to_h.values_at(:entry_id, :state, :disposition, :edit_lock) })
      .to contain_exactly([draft_entry.id, :committed, :active, true], [linked_entry.id, :committed, :active, false])
  end

  it "reads back a resume holding only the financial snapshot" do
    only_snapshot = Timekeeping::FirstCutover::Resume.new(financial_snapshot: Timekeeping::FinancialSnapshot.process)
    journal.record(only_snapshot)

    expect(journal.resume).to eq(only_snapshot)
  end

  it "replaces the record whole on each write, and writes it for its owner only" do
    journal.record(Timekeeping::FirstCutover::Resume.new(financial_snapshot: { "invoices" => {} }))
    journal.record(resume)

    expect(journal.resume).to eq(resume)
    expect(journal.path.stat.mode & 0o777).to eq(0o600)
    expect(journal.path.dirname.children).to eq([journal.path])
  end

  it "keeps the previous record when a write fails part way" do
    journal.record(resume)
    allow(JSON).to receive(:generate).and_raise(Errno::ENOSPC)

    expect { journal.record(Timekeeping::FirstCutover::Resume.new) }.to raise_error(Errno::ENOSPC)
    expect(described_class.new(path: journal.path).resume).to eq(resume)
  end

  it "forgets the record on clear, and clears an empty journal too" do
    journal.record(resume)

    journal.clear
    expect(journal.path).not_to exist
    expect(journal.resume).to eq(Timekeeping::FirstCutover::Resume.new)
    expect { journal.clear }.not_to raise_error
  end

  {
    "not JSON" => "{",
    "another format" => JSON.generate("format" => 2, "financial_snapshot" => nil, "checkpoint" => nil),
    "a checkpoint missing its reservations" =>
      JSON.generate("format" => 1, "financial_snapshot" => nil, "checkpoint" => { "generation" => 1, "entries" => [] })
  }.each do |name, content|
    it "refuses a file holding #{name} rather than take it for an empty journal, and leaves it as it is" do
      journal.path.dirname.mkpath
      journal.path.write(content)

      expect { journal.resume }.to raise_error(described_class::Unreadable, /cannot be read/)
      expect(journal.path.read).to eq(content)
    end
  end

  it "takes a relative path from the application's root" do
    expect(described_class.new.path).to eq(Rails.root.join("tmp/timekeeping/first_cutover.json"))
  end
end
