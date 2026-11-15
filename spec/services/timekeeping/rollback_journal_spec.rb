# frozen_string_literal: true

require "rails_helper"

# The rollback's journal (docs/architecture/timekeeping-soa.md §10.5: "can
# resume from the step that failed"): the financial snapshot an interrupted
# run of the rollback took, kept in a file so a run in another process checks
# the money against it. The snapshot is a real one, of two tenants' billing.
RSpec.describe Timekeeping::RollbackJournal, type: :model do
  include_context "with two Timekeeping tenants"

  let(:directory) { Pathname(Dir.mktmpdir("timekeeping-journal")) }
  let(:journal) { described_class.new(path: directory.join("handoff/rollback.json")) }

  let!(:draft_entry) { unbilled_entry(tenant_a, duration: 479.99999) }
  let!(:draft) { invoice_for(tenant_a).tap { |invoice| direct_line(invoice, draft_entry).then { invoice.reload.save! } } }
  let!(:sent) { invoice_for(tenant_b, status: :sent).tap { |invoice| direct_line(invoice, unbilled_entry(tenant_b, duration: 0.1)) } }

  let(:resume) { Timekeeping::Rollback::Resume.new(financial_snapshot: Timekeeping::FinancialSnapshot.process) }

  after { FileUtils.rm_rf(directory) }

  it "answers an empty resume while nothing is recorded" do
    expect(journal.resume).to eq(Timekeeping::Rollback::Resume.new)
    expect(journal.path).not_to exist
  end

  it "reads back exactly the financial snapshot it recorded, in another instance" do
    journal.record(resume)

    read = described_class.new(path: journal.path).resume

    expect(read).to eq(resume)
    expect(read.financial_snapshot.fetch("invoices").keys).to include(draft.id.to_s, sent.id.to_s)
    expect(Timekeeping::FinancialSnapshot.diff(read.financial_snapshot, Timekeeping::FinancialSnapshot.process)).to be_empty
  end

  it "reads back the empty resume a handoff records as it starts" do
    journal.record(resume)
    journal.record(Timekeeping::Rollback::Resume.new)

    expect(journal.resume).to eq(Timekeeping::Rollback::Resume.new)
    expect(journal.path).to exist
  end

  it "replaces the record whole on each write, and writes it for its owner only" do
    journal.record(Timekeeping::Rollback::Resume.new(financial_snapshot: { "invoices" => {} }))
    journal.record(resume)

    expect(journal.resume).to eq(resume)
    expect(journal.path.stat.mode & 0o777).to eq(0o600)
    expect(journal.path.dirname.children).to eq([journal.path])
  end

  it "keeps the previous record when a write fails part way" do
    journal.record(resume)
    allow(JSON).to receive(:generate).and_raise(Errno::ENOSPC)

    expect { journal.record(Timekeeping::Rollback::Resume.new) }.to raise_error(Errno::ENOSPC)
    expect(described_class.new(path: journal.path).resume).to eq(resume)
  end

  it "forgets the record on clear, and clears an empty journal too" do
    journal.record(resume)

    journal.clear
    expect(journal.path).not_to exist
    expect(journal.resume).to eq(Timekeeping::Rollback::Resume.new)
    expect { journal.clear }.not_to raise_error
  end

  it "refuses a first cutover's journal handed to it, and leaves the file as it is" do
    first_cutover = Timekeeping::FirstCutoverJournal.new(path: journal.path)
    first_cutover.record(Timekeeping::FirstCutover::Resume.new(financial_snapshot: resume.financial_snapshot))
    content = journal.path.read

    expect { journal.resume }.to raise_error(Timekeeping::HandoffJournal::Unreadable, /rollback journal .* cannot be read/)
    expect(journal.path.read).to eq(content)
  end

  it "is refused by the first cutover's journal in turn" do
    journal.record(resume)

    expect { Timekeeping::FirstCutoverJournal.new(path: journal.path).resume }
      .to raise_error(Timekeeping::FirstCutoverJournal::Unreadable, /first cutover journal .* cannot be read/)
  end

  {
    "not JSON" => "{",
    "another format" => JSON.generate("format" => 2, "handoff" => "rollback", "financial_snapshot" => nil),
    "another handoff" => JSON.generate("format" => 1, "handoff" => "re_cutover", "financial_snapshot" => nil),
    "no financial snapshot" => JSON.generate("format" => 1, "handoff" => "rollback")
  }.each do |name, content|
    it "refuses a file holding #{name} rather than take it for an empty journal, and leaves it as it is" do
      journal.path.dirname.mkpath
      journal.path.write(content)

      expect { journal.resume }.to raise_error(described_class::Unreadable, /cannot be read/)
      expect(journal.path.read).to eq(content)
    end
  end

  it "takes a relative path from the application's root" do
    expect(described_class.new.path).to eq(Rails.root.join("tmp/timekeeping/rollback.json"))
  end
end
