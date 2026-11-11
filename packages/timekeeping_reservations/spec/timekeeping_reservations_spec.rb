# frozen_string_literal: true

require "json"
require_relative "../lib/timekeeping_reservations"

# The shared decision table of docs/architecture/timekeeping-soa.md §7.2,
# tested row by row, once, in its package (§12.3).
RSpec.describe TimekeepingReservations do
  subject(:rule) { described_class }

  let(:company_id) { 42 }
  let(:invoice_id) { 1 }
  let(:other_invoice_id) { 2 }

  def operation(kind:, invoice_state:, entry_ids: [], invoice: invoice_id, operation_id: "op-#{invoice}", company: company_id)
    described_class::Operation.new(invoice_id: invoice, operation_id:, company_id: company, kind:, invoice_state:, entry_ids:)
  end

  def committed(entry_id, invoice: invoice_id, edit_lock: true, disposition: :active)
    described_class::Reservation.new(
      entry_id:, invoice_id: invoice, company_id:, operation_id: nil, state: :committed, disposition:, edit_lock:
    )
  end

  def provisional(entry_id, invoice: invoice_id, edit_lock: true, operation_id: "op-#{invoice}")
    described_class::Reservation.new(
      entry_id:, invoice_id: invoice, company_id:, operation_id:, state: :provisional, disposition: :active, edit_lock:
    )
  end

  def entries(*ids, company: company_id)
    ids.to_h { |id| [id, described_class::Entry.new(id:, company_id: company)] }
  end

  def prepared(op, reservations: [], found: op.entry_ids)
    result = rule.prepare(op, entries: entries(*found), reservations:)
    expect(result).to be_a(described_class::Prepared)
    result.reservations
  end

  # Prepare, then commit what prepare returned: the whole operation.
  def saved(op, reservations: [])
    rule.commit(op, reservations: prepared(op, reservations:))
  end

  describe "the table" do
    it "has exactly one row for every operation, invoice state and entry relation" do
      expected = described_class::KINDS.flat_map do |kind|
        relations = described_class::RELATIONS.fetch(kind).call([], []).keys
        described_class::INVOICE_STATES.product(relations).map { |state, relation| [kind, state, relation] }
      end

      expect(described_class::TABLE.keys).to match_array(expected)
      expect(described_class::TABLE.values.flat_map(&:values)).to all(satisfy { |effect| described_class::EFFECTS.key?(effect) })
    end

    it "speaks the reservation contract's kinds, invoice states and refusal reasons" do
      contracts = File.expand_path("../contracts/v1", __dir__)
      reservation_api = JSON.parse(File.read(File.join(contracts, "reservation_api.json")))
      common = JSON.parse(File.read(File.join(contracts, "common.json")))
      request = reservation_api.dig("$defs", "prepare_request", "properties")
      reasons = common.dig("$defs", "problem", "properties", "refused", "items", "properties", "reason", "enum")

      expect(described_class::KINDS.map(&:to_s)).to eq(request.dig("kind", "enum"))
      expect(described_class::INVOICE_STATES.map(&:to_s)).to eq(request.dig("invoice_state", "enum"))
      expect(described_class::REFUSALS.keys.map(&:to_s)).to match_array(reasons)
    end

    it "refuses an operation it has no row for" do
      expect { operation(kind: :void, invoice_state: :draft) }.to raise_error(ArgumentError, /kind :void/)
      expect { operation(kind: :save, invoice_state: "draft") }.to raise_error(ArgumentError, /invoice state "draft"/)
    end
  end

  describe "save, draft" do
    it "added: provisional with edit_lock at prepare, active with edit_lock at commit (L1)" do
      op = operation(kind: :save, invoice_state: :draft, entry_ids: [101])

      expect(prepared(op)).to eq([provisional(101)])
      expect(rule.commit(op, reservations: [provisional(101)])).to eq([committed(101)])
    end

    it "kept: nothing at prepare, edit_lock set at commit, since a draft save re-locks all (L1)" do
      op = operation(kind: :save, invoice_state: :draft, entry_ids: [101])
      before = [committed(101, edit_lock: false)]

      expect(prepared(op, reservations: before)).to eq(before)
      expect(rule.commit(op, reservations: before)).to eq([committed(101)])
    end

    it "removed: nothing at prepare, released at commit (L4, F3)" do
      op = operation(kind: :save, invoice_state: :draft, entry_ids: [])
      before = [committed(101)]

      expect(prepared(op, reservations: before)).to eq(before)
      expect(rule.commit(op, reservations: before)).to be_empty
    end
  end

  describe "save, non-draft" do
    it "added: provisional with no lock at prepare, active with no lock at commit (L1)" do
      op = operation(kind: :save, invoice_state: :non_draft, entry_ids: [101])

      expect(prepared(op)).to eq([provisional(101, edit_lock: false)])
      expect(rule.commit(op, reservations: [provisional(101, edit_lock: false)])).to eq([committed(101, edit_lock: false)])
    end

    it "kept: unchanged at prepare and at commit" do
      op = operation(kind: :save, invoice_state: :non_draft, entry_ids: [101, 102])
      before = [committed(101), committed(102, edit_lock: false)]

      expect(prepared(op, reservations: before)).to eq(before)
      expect(rule.commit(op, reservations: before)).to eq(before)
    end

    it "removed: nothing at prepare, retained with its edit_lock at commit (L4)" do
      op = operation(kind: :save, invoice_state: :non_draft, entry_ids: [])
      before = [committed(101), committed(102, edit_lock: false)]

      expect(prepared(op, reservations: before)).to eq(before)
      expect(rule.commit(op, reservations: before)).to contain_exactly(
        committed(101, disposition: :retained),
        committed(102, edit_lock: false, disposition: :retained)
      )
    end
  end

  describe "discard" do
    let(:before) { [committed(101), committed(102)] }

    it "draft, all: nothing at prepare, released at commit (F2; today they stay locked, K2)" do
      op = operation(kind: :discard, invoice_state: :draft)

      expect(prepared(op, reservations: before)).to eq(before)
      expect(rule.commit(op, reservations: before)).to be_empty
    end

    it "non-draft, all: nothing at prepare, retained at commit (L3)" do
      op = operation(kind: :discard, invoice_state: :non_draft)

      expect(prepared(op, reservations: before)).to eq(before)
      expect(rule.commit(op, reservations: before)).to contain_exactly(
        committed(101, disposition: :retained), committed(102, disposition: :retained)
      )
    end
  end

  describe "destroy" do
    let(:before) { [committed(101), committed(102)] }

    it "draft, all: nothing at prepare, released at commit (K7; F3 for linked entries)" do
      op = operation(kind: :destroy, invoice_state: :draft)

      expect(prepared(op, reservations: before)).to eq(before)
      expect(rule.commit(op, reservations: before)).to be_empty
    end

    it "non-draft, all: nothing at prepare, retained at commit, the reservation carrying the owner (K7, §7.3)" do
      op = operation(kind: :destroy, invoice_state: :non_draft)

      expect(prepared(op, reservations: before)).to eq(before)
      expect(rule.commit(op, reservations: before)).to all(have_attributes(
        invoice_id:, company_id:, state: :committed, disposition: :retained, edit_lock: true
      ))
    end
  end

  describe "any operation, an entry already reserved elsewhere" do
    let(:op) { operation(kind: :save, invoice_state: :draft, entry_ids: [101, 205]) }

    it "refuses an entry with an active reservation by another kept invoice (F1; today allowed, K6)" do
      result = rule.prepare(op, entries: entries(101, 205), reservations: [committed(205, invoice: other_invoice_id)])

      expect(result).to eq(described_class::Refused.new(refusals: [described_class::Refusal.new(entry_id: 205, reason: :on_other_invoice)]))
    end

    it "refuses an entry with a provisional reservation by another operation (§7.1)" do
      other = provisional(205, invoice: other_invoice_id, edit_lock: false)

      expect(rule.prepare(op, entries: entries(101, 205), reservations: [other]))
        .to eq(described_class::Refused.new(refusals: [described_class::Refusal.new(entry_id: 205, reason: :on_other_invoice)]))
    end

    it "reserves an entry retained by another invoice provisionally, keeping the old reservation" do
      retained = committed(205, invoice: other_invoice_id, disposition: :retained)

      expect(prepared(op, reservations: [retained])).to contain_exactly(provisional(101), provisional(205), retained)
    end

    it "succeeds the retained reservation at commit and removes it (§7.1)" do
      retained = committed(205, invoice: other_invoice_id, disposition: :retained)

      expect(saved(op, reservations: [retained])).to contain_exactly(committed(101), committed(205))
    end

    it "leaves the retained reservation untouched when the successor aborts" do
      retained = committed(205, invoice: other_invoice_id, disposition: :retained)

      expect(rule.abort(op, reservations: prepared(op, reservations: [retained]))).to eq([retained])
    end

    it "lets the invoice that retained an entry take it back as active" do
      retained = committed(205, disposition: :retained)
      op = operation(kind: :save, invoice_state: :non_draft, entry_ids: [205])

      expect(saved(op, reservations: [retained])).to eq([committed(205, edit_lock: false)])
    end
  end

  describe "prepare refusals" do
    let(:op) { operation(kind: :save, invoice_state: :draft, entry_ids: [101, 102, 103]) }

    it "refuses a missing entry, an entry of another company and a reserved entry, each once, first reason winning" do
      found = entries(101).merge(entries(102, company: 7))
      reservations = [committed(101, invoice: other_invoice_id), committed(102, invoice: other_invoice_id)]

      expect(rule.prepare(op, entries: found, reservations:).refusals).to eq([
        described_class::Refusal.new(entry_id: 101, reason: :on_other_invoice),
        described_class::Refusal.new(entry_id: 102, reason: :wrong_company),
        described_class::Refusal.new(entry_id: 103, reason: :not_found)
      ])
    end

    it "reserves nothing when any entry is refused" do
      result = rule.prepare(op, entries: entries(101, 102), reservations: [])

      expect(result).to be_a(described_class::Refused)
      expect(result.refusals.map(&:entry_id)).to eq([103])
    end

    it "checks only the entries the operation adds, not those the invoice already holds (L8 was decided then)" do
      held = operation(kind: :save, invoice_state: :draft, entry_ids: [101])

      expect(rule.prepare(held, entries: {}, reservations: [committed(101)])).to be_a(described_class::Prepared)
    end
  end

  describe "a project aggregate line removed from a draft (§12.4, F3)" do
    # A direct line for X and a grouped line that references X and Y.
    let(:x) { 101 }
    let(:y) { 102 }
    let(:draft) { [committed(x), committed(y)] }

    it "keeps X while the direct line still references it and releases Y; removing the direct line releases X" do
      without_grouped = saved(operation(kind: :save, invoice_state: :draft, entry_ids: [x]), reservations: draft)
      expect(without_grouped).to eq([committed(x)])

      expect(saved(operation(kind: :save, invoice_state: :draft, entry_ids: []), reservations: without_grouped)).to be_empty
    end

    it "releases the whole set when the draft is destroyed" do
      expect(saved(operation(kind: :destroy, invoice_state: :draft), reservations: draft)).to be_empty
    end

    it "keeps every prior reservation when the save or destroy fails and aborts" do
      [
        operation(kind: :save, invoice_state: :draft, entry_ids: [x, 103]),
        operation(kind: :save, invoice_state: :draft, entry_ids: [x]),
        operation(kind: :destroy, invoice_state: :draft)
      ].each do |op|
        expect(rule.abort(op, reservations: prepared(op, reservations: draft))).to match_array(draft)
      end
    end
  end

  describe "abort" do
    it "drops only this operation's provisional reservations" do
      op = operation(kind: :save, invoice_state: :draft, entry_ids: [101])
      others = [committed(102), provisional(103, invoice: other_invoice_id), committed(104, disposition: :retained)]

      expect(rule.abort(op, reservations: [provisional(101), *others])).to match_array(others)
    end
  end

  describe "idempotency" do
    it "gives the same reservations when prepare, commit or abort is applied twice" do
      op = operation(kind: :save, invoice_state: :draft, entry_ids: [101, 102])
      before = [committed(102, edit_lock: false), committed(103)]
      once = prepared(op, reservations: before)

      expect(prepared(op, reservations: once)).to match_array(once)
      expect(rule.commit(op, reservations: rule.commit(op, reservations: once))).to match_array(rule.commit(op, reservations: once))
      expect(rule.abort(op, reservations: rule.abort(op, reservations: once))).to match_array(before)
    end

    it "raises when commit adds an entry its operation never prepared" do
      op = operation(kind: :save, invoice_state: :draft, entry_ids: [101])

      expect { rule.commit(op, reservations: []) }
        .to raise_error(described_class::ProtocolError, /op-1 did not prepare entry 101/)
    end
  end

  describe "the derived facts" do
    it "is locked exactly when the entry holds a reservation with edit_lock, provisional and retained included (§7.1)" do
      reservations = [
        provisional(1), committed(2), committed(3, disposition: :retained),
        committed(4, edit_lock: false), committed(5, edit_lock: false, disposition: :retained)
      ]

      expect((1..6).select { |id| rule.locked?(id, reservations) }).to eq([1, 2, 3])
    end

    it "is selectable unless the entry holds an active or provisional reservation; retained does not count (L3, L4)" do
      reservations = [
        provisional(1, edit_lock: false), committed(2, edit_lock: false), committed(3, disposition: :retained)
      ]

      expect((1..4).select { |id| rule.selectable?(id, reservations) }).to eq([3, 4])
    end
  end

  describe "tenants" do
    it "reserves under the operation's company and refuses an entry of the other one (§6.3, L8)" do
      fork_and_leaf = operation(kind: :save, invoice_state: :draft, entry_ids: [101], company: 1, invoice: 10)
      copper_kettle = operation(kind: :save, invoice_state: :draft, entry_ids: [201], company: 2, invoice: 20)

      reservations = rule.prepare(fork_and_leaf, entries: entries(101, company: 1), reservations: []).reservations
      refused = rule.prepare(
        operation(kind: :save, invoice_state: :draft, entry_ids: [101], company: 2, invoice: 20),
        entries: entries(101, company: 1), reservations:
      )

      expect(refused.refusals).to eq([described_class::Refusal.new(entry_id: 101, reason: :wrong_company)])
      expect(rule.prepare(copper_kettle, entries: entries(201, company: 2), reservations:).reservations
        .map { |reservation| [reservation.entry_id, reservation.company_id] }).to contain_exactly([101, 1], [201, 2])
    end
  end
end
