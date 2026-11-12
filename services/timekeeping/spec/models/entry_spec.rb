# frozen_string_literal: true

require "rails_helper"

# §3.2, §5.1, §7.1: an entry is answered as the contract's full entry, with
# its tenant and version, `duration` the stored float, and `locked` derived
# from its reservations by the shared rule.
RSpec.describe Entry do
  it "answers the contract's full entry" do
    entry = entry!(company_id: 1, agent_id: 4, note: "Prep", source: "mcp", source_metadata: { "mcp_server" => "x" })

    contract = entry.to_contract

    expect(contract_errors("common", "#/$defs/entry", contract)).to be_empty
    expect(contract).to include(
      "id" => entry.id, "company_id" => 1, "version" => 1, "agent_id" => 4, "work_date" => "2026-11-02",
      "bill_status" => "unbilled", "review_status" => "not_required", "source" => "mcp", "locked" => false,
      "discarded_at" => nil, "created_at" => entry.created_at.utc.iso8601(6)
    )
  end

  it "carries duration as the stored float, which JSON parses back unchanged" do
    [90.7, 0.1, 479.99999].each do |duration|
      carried = JSON.parse(JSON.generate(entry!(company_id: 1, duration:).to_contract)).fetch("duration")

      expect(carried).to eq(duration)
    end
  end

  {
    "no reservation" => [[], false],
    "an active reservation with the edit lock" => [[{ invoice_id: 1 }], true],
    "an active reservation without it, on an invoice created as non-draft" => [[{ invoice_id: 1, edit_lock: false }], false],
    "a retained reservation with the edit lock" => [[{ invoice_id: 1, disposition: "retained" }], true],
    "a provisional reservation with the edit lock" => [[{ invoice_id: 1, state: "provisional" }], true],
    "a retained lock and an unlocked provisional successor" => [
      [{ invoice_id: 1, disposition: "retained" }, { invoice_id: 2, state: "provisional", edit_lock: false }], true
    ]
  }.each do |name, (reservations, locked)|
    it "is #{locked ? '' : 'not '}locked with #{name}" do
      entry = entry!(company_id: 1)
      reservations.each { |reservation| reservation!(entry, **reservation) }

      expect(entry.reload.to_contract.fetch("locked")).to be(locked)
    end
  end

  it "stores only the enum values the contracts list" do
    expect { entry!(company_id: 1, bill_status: "billable") }.to raise_error(ActiveRecord::StatementInvalid, /entries_bill_status/)
    expect { entry!(company_id: 1, source: "harvest") }.to raise_error(ActiveRecord::StatementInvalid, /entries_source/)
  end

  it "holds at most one active reservation per entry" do
    entry = entry!(company_id: 1)
    reservation!(entry, invoice_id: 1)

    expect { reservation!(entry, invoice_id: 2) }.to raise_error(ActiveRecord::RecordNotUnique, /one_live_per_entry/)
  end
end
