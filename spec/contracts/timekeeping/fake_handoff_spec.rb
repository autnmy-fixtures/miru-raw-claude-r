# frozen_string_literal: true

require "rails_helper"

# The consumer-side fake of Timekeeping's handoff API holds to its contract
# (handoff_api.json; docs/architecture/timekeeping-soa.md §10.5, §12.3). It
# is driven over HTTP, as the handoff tool will drive it.
RSpec.describe TimekeepingContracts::FakeHandoff do
  subject!(:fake) { described_class.new.install! }

  let(:http) { Faraday.new(url: described_class::URL) { |connection| connection.response :json } }

  def handoff_token(key: TimekeepingContracts::TEST_TOKEN_KEY, **overrides)
    TimekeepingContracts.sign({ "sub" => "service:timekeeping-handoff", "aud" => "handoff" }.merge(overrides), key:)
  end

  def request(operation_name, body: nil, query: nil, generation: body&.fetch("generation"), token: handoff_token, without: [], **params)
    operation = TimekeepingContracts.operation(operation_name)
    sent = { "Authorization" => "Bearer #{token}", "X-Request-Id" => "handoff-1" }
    sent = sent.merge("X-Ownership-Generation" => generation.to_s, "Content-Type" => "application/json") if operation.mutating
    path = [operation.path_for(**params), query && URI.encode_www_form(query)].compact.join("?")
    http.run_request(operation.verb.downcase.to_sym, path, body && JSON.generate(body), sent.except(*without))
  end

  def take(generation, **options) = request(:take_checkpoint, query: { "generation" => generation.to_s }, **options)

  def step(name, generation) = request(:run_step, step: name.to_s, body: { "generation" => generation })

  def entry(id:, company_id:, **fields)
    TimekeepingContracts::ENTRY_DEFAULTS.merge(
      "id" => id, "company_id" => company_id, "version" => 1, "project_id" => 10 + company_id, "user_id" => 7,
      "duration" => 90.7, "work_date" => "2026-11-02",
      "created_at" => "2026-11-02T09:15:30.123456Z", "updated_at" => "2026-11-03T17:45:01.654321Z"
    ).merge(fields.transform_keys(&:to_s))
  end

  def reservation(entry_id:, invoice_id:, company_id:, disposition: "active", edit_lock: true)
    { "entry_id" => entry_id, "invoice_id" => invoice_id, "company_id" => company_id, "operation_id" => nil,
      "state" => "committed", "disposition" => disposition, "edit_lock" => edit_lock }
  end

  # Two tenants, as the legacy checkpoint carries them.
  let(:entries) do
    [entry(id: 102, company_id: 1, duration: 479.99999), entry(id: 101, company_id: 1, locked: true, duration: 0.1), entry(id: 205, company_id: 2)]
  end
  let(:reservations) do
    [reservation(entry_id: 101, invoice_id: 501, company_id: 1), reservation(entry_id: 102, invoice_id: 502, company_id: 1, edit_lock: false)]
  end
  let(:checkpoint) { { "generation" => 1, "entries" => entries, "reservations" => reservations } }

  def frozen!
    step(:close, 0)
    step(:freeze, 1)
  end

  def type(slug) = TimekeepingContracts.problem_type(slug)

  after { expect(fake.violations).to be_empty unless RSpec.current_example.metadata[:violates] }

  it "answers Timekeeping's copy before any handoff, and an empty outbox" do
    response = request(:read_handoff)

    expect(response.status).to eq(200)
    expect(response.body).to eq(
      "ownership" => { "generation" => 0, "owner" => "legacy", "state" => "open" },
      "outbox" => { "latest_position" => nil, "undelivered" => 0 }
    )
  end

  it "moves its copy through the shared state machine: close raises the generation, freeze, flip to the incoming owner" do
    expect(step(:close, 0).body["ownership"]).to eq("generation" => 1, "owner" => "legacy", "state" => "closed")
    expect(step(:freeze, 1).body["ownership"]).to eq("generation" => 1, "owner" => "legacy", "state" => "frozen")
    expect(step(:flip, 1).body["ownership"]).to eq("generation" => 1, "owner" => "timekeeping", "state" => "open")
    expect(fake.copy).to eq(described_class::Copy.new(generation: 1, owner: "timekeeping", state: "open"))
    expect(fake.calls.map(&:operation)).to eq(%i[run_step run_step run_step])
  end

  it "aborts back to the outgoing owner, keeping the raised generation" do
    step(:close, 0)

    expect(step(:abort, 1).body["ownership"]).to eq("generation" => 1, "owner" => "legacy", "state" => "open")
  end

  it "refuses a replayed or misordered step as out-of-step and changes nothing" do
    step(:close, 0)

    [[:close, 0], [:close, 1], [:flip, 1], [:freeze, 2]].each do |name, generation|
      refused = step(name, generation)

      expect([refused.status, refused.body["type"]]).to eq([409, type("out-of-step")]), name.to_s
    end
    expect(fake.copy).to eq(described_class::Copy.new(generation: 1, owner: "legacy", state: "closed"))
  end

  it "answers an unknown step not-found" do
    refused = step(:settle, 0)

    expect([refused.status, refused.body["type"]]).to eq([404, type("not-found")])
    expect(fake.copy.state).to eq("open")
  end

  describe "the checkpoint" do
    it "loads once while frozen under legacy, writing one undelivered snapshot per entry" do
      frozen!

      loaded = request(:load_checkpoint, body: checkpoint)

      expect([loaded.status, loaded.body]).to eq([200, { "entries" => 3, "reservations" => 2 }])
      expect(fake.loaded).to eq(checkpoint)
      expect(fake.calls.last.request_id).to eq("handoff-1")
      expect(request(:read_handoff).body["outbox"]).to eq("latest_position" => 3, "undelivered" => 3)
      expect(fake.undelivered.pluck("entry_id", "version", "company_id")).to eq([[101, 1, 1], [102, 1, 1], [205, 1, 2]])
      expect(fake.undelivered.first["data"]).to include("locked" => true, "duration" => 0.1)
      fake.undelivered.each { |snapshot| TimekeepingContracts.validate!(:entry_snapshot, "#/$defs/entry_snapshot", snapshot) }
    end

    it "refuses a second load as already-loaded and keeps the first" do
      frozen!
      request(:load_checkpoint, body: checkpoint)

      refused = request(:load_checkpoint, body: checkpoint.merge("entries" => [entry(id: 900, company_id: 1)]))

      expect([refused.status, refused.body["type"]]).to eq([409, type("already-loaded")])
      expect(fake.loaded).to eq(checkpoint)
      expect(fake.outbox.size).to eq(3)
    end

    it "refuses a load or a reconcile unless the copy is frozen under legacy at the checkpoint's generation" do
      [-> { nil }, -> { step(:close, 0) }, -> { step(:freeze, 1) && step(:flip, 1) }].each do |reach|
        reach.call
        %i[load_checkpoint reconcile_checkpoint].each do |name|
          refused = request(name, body: checkpoint)

          expect([refused.status, refused.body["type"]]).to eq([409, type("out-of-step")]), "#{name} at #{fake.copy.to_h}"
        end
      end
      expect(fake.loaded).to be_nil
    end

    it "refuses a load at another generation than the frozen copy's" do
      frozen!

      refused = request(:load_checkpoint, body: checkpoint.merge("generation" => 2))

      expect(refused.status).to eq(409)
      expect(fake.loaded).to be_nil
    end

    it "refuses a checkpoint whose entry is not a contract entry, listing it, and loads nothing" do
      frozen!

      refused = request(:load_checkpoint, body: checkpoint.merge("entries" => [entries.first, entries.last.except("duration")]))

      expect([refused.status, refused.body["type"], refused.body["lists"]]).to eq([422, type("checkpoint-refused"), { "not_a_contract_entry" => [205] }])
      expect(fake.loaded).to be_nil
      expect(fake.outbox).to be_empty
    end

    it "reconciles the checkpoint it loaded, in any order, and writes nothing" do
      frozen!
      request(:load_checkpoint, body: checkpoint)

      reconciled = request(:reconcile_checkpoint, body: checkpoint.merge("entries" => entries.reverse, "reservations" => reservations.reverse))

      expect([reconciled.status, reconciled.body]).to eq([200, { "entries" => 3, "reservations" => 2 }])
      expect(fake.copy.state).to eq("frozen")
      expect(fake.outbox.size).to eq(3)
    end

    it "lists every difference from what it loaded as checkpoint-differs" do
      frozen!
      request(:load_checkpoint, body: checkpoint)
      carried = {
        "generation" => 1,
        "entries" => [entries[0].merge("duration" => 479.9999900000001), entries[1], entry(id: 300, company_id: 2)],
        "reservations" => [reservations[0].merge("disposition" => "retained")]
      }

      refused = request(:reconcile_checkpoint, body: carried)

      expect([refused.status, refused.body["type"]]).to eq([409, type("checkpoint-differs")])
      expect(refused.body["lists"]).to eq(
        "entry_missing" => [300], "entry_unexpected" => [205], "entry_differs" => [102], "reservations_differ" => [101, 102]
      )
    end

    it "lists every carried entry as missing before a load" do
      frozen!

      expect(request(:reconcile_checkpoint, body: checkpoint).body["lists"]).to include("entry_missing" => [101, 102, 205])
    end
  end

  describe "the rollback's checkpoint, taken out of Timekeeping" do
    subject!(:fake) { described_class.new(generation: 1, owner: "timekeeping").install! }

    let(:audit) do
      { "id" => 9, "entry_id" => 101, "company_id" => 1, "version" => 1, "action" => "create", "actor" => "user:7", "agent_id" => nil,
        "writer" => "web", "request_id" => "req-1", "audited_changes" => { "note" => nil }, "created_at" => "2026-11-02T09:15:30.123456Z" }
    end
    let(:receipt) do
      { "company_id" => 2, "key" => "web-1", "request_digest" => "d2", "status" => 201, "response" => { "entry" => { "id" => 205 } },
        "created_at" => "2026-11-02T09:15:30.123456Z" }
    end
    let(:noop_abort) do
      { "invoice_id" => 701, "operation_id" => "8f14e45f-ceea-467f-a0e3-b4a1c3d2e5f6", "company_id" => nil, "kind" => nil, "invoice_state" => nil,
        "entry_ids" => [], "state" => "aborted", "created_at" => "2026-11-02T09:15:30.123456Z", "updated_at" => "2026-11-02T09:15:30.123456Z" }
    end

    def frozen_for_rollback!
      step(:close, 1)
      step(:freeze, 2)
    end

    it "answers what it holds while frozen under timekeeping at the query's generation, and writes nothing" do
      fake.hold!(entries:, reservations:, entry_audits: [audit], reservation_operations: [noop_abort], idempotency_receipts: [receipt])
      frozen_for_rollback!

      taken = take(2)

      expect(taken.status).to eq(200)
      expect(taken.body).to eq(
        "generation" => 2, "entries" => entries, "reservations" => reservations,
        "entry_audits" => [audit], "reservation_operations" => [noop_abort], "idempotency_receipts" => [receipt]
      )
      expect(taken.body.dig("entries", 0, "duration")).to eq(479.99999)
      TimekeepingContracts.validate!(:handoff_api, "#/$defs/taken_checkpoint", taken.body)
      expect(fake.calls.last).to have_attributes(operation: :take_checkpoint, input: { "generation" => "2" })
      expect(take(2).body).to eq(taken.body)
      expect(fake.copy).to eq(described_class::Copy.new(generation: 2, owner: "timekeeping", state: "frozen"))
      expect(fake.outbox).to be_empty
    end

    it "answers an empty checkpoint when it holds nothing" do
      frozen_for_rollback!

      expect(take(2).body).to eq("generation" => 2, **described_class::HELD.index_with { [] })
    end

    it "holds what a first cutover loaded, so the rollback takes back what the cutover carried" do
      legacy = described_class.new.install!
      frozen!
      request(:load_checkpoint, body: checkpoint)
      step(:flip, 1)
      step(:close, 1)
      step(:freeze, 2)

      taken = take(2)

      expect(taken.body.slice("entries", "reservations")).to eq(checkpoint.slice("entries", "reservations"))
      expect(taken.body.slice("entry_audits", "reservation_operations", "idempotency_receipts").values).to eq([[], [], []])
      expect(legacy.violations).to be_empty
    end

    it "refuses the take anywhere but frozen under timekeeping at the query's generation, and changes nothing" do
      fake.hold!(entries:)

      [[-> { nil }, 1], [-> { step(:close, 1) }, 2], [-> { step(:freeze, 2) }, 1], [-> { nil }, 3]].each do |reach, asked|
        reach.call
        refused = take(asked)

        expect([refused.status, refused.body["type"]]).to eq([409, type("out-of-step")]), "asked #{asked} at #{fake.copy.to_h}"
      end
      expect(fake.copy.state).to eq("frozen")
    end

    it "refuses the take under legacy: the first cutover's copy has nothing to give back" do
      described_class.new.install!.tap do |legacy|
        frozen!

        refused = take(1)

        expect([refused.status, refused.body["type"]]).to eq([409, type("out-of-step")])
        expect(refused.body["detail"]).to include("expects owner timekeeping, found owner legacy")
        expect(legacy.violations).to be_empty
      end
    end

    it "answers a scripted checkpoint-unsettled with its lists" do
      frozen_for_rollback!
      fake.fail_next(:take_checkpoint, status: 409, slug: "checkpoint-unsettled", lists: { "provisional_reservation" => [101] })

      refused = take(2)

      expect([refused.status, refused.body["type"], refused.body["lists"]]).to eq([409, type("checkpoint-unsettled"), { "provisional_reservation" => [101] }])
      expect(take(2).status).to eq(200)
    end

    it "records a query outside the contract", :violates do
      frozen_for_rollback!

      [{}, { "generation" => "-1" }, { "generation" => "02" }, { "generation" => "two" }, { "generation" => "2", "owner" => "timekeeping" }].each do |query|
        expect(request(:take_checkpoint, query: query.presence).status).to eq(400), query.inspect
      end
      expect(fake.violations.size).to eq(5)
    end

    it "refuses to hold a part outside the contract, keeping what it held" do
      fake.hold!(entries:)
      provisional = reservations.first.merge("state" => "provisional")

      expect { fake.hold!(reservations: [provisional]) }.to raise_error(TimekeepingContracts::Violation, /taken_checkpoint/)
      expect { fake.hold!(payments: []) }.to raise_error(ArgumentError, /payments/)
      expect(fake.held).to eq(described_class::HELD.index_with { [] }.merge("entries" => entries))
    end

    it "takes an entry write as the owner: the take answers the written entry, and its snapshot waits in the outbox" do
      fake.hold!(entries:)
      written = entries.find { |held| held.fetch("id") == 205 }.merge("note" => "Proofing", "version" => 2)

      fake.write!(written)

      expect(fake.held.fetch("entries").map { |held| held.values_at("id", "version") }).to eq([[101, 1], [102, 1], [205, 2]])
      expect(fake.undelivered.map { |snapshot| snapshot.values_at("entry_id", "version") }).to eq([[205, 2]])
      expect(request(:read_handoff).body["outbox"]).to eq("latest_position" => 1, "undelivered" => 1)
      frozen_for_rollback!
      expect(take(2).body.fetch("entries").find { |held| held.fetch("id") == 205 }).to eq(written)
    end
  end

  describe "the re-cutover's checkpoint, loaded into Timekeeping and reconciled" do
    # The prepared application owns the entries after a rollback at
    # generation 2; Timekeeping still holds the entries it held then.
    subject!(:fake) { described_class.new(generation: 2, owner: "monolith").install!.hold!(entries:, reservations:) }

    let(:created_at) { "2026-11-02T09:15:30.123456Z" }
    let(:audit) do
      { "id" => 15, "entry_id" => 240, "company_id" => 2, "version" => 1, "action" => "create", "actor" => "user:8", "agent_id" => nil,
        "writer" => "web", "request_id" => "req-3", "audited_changes" => { "note" => nil }, "created_at" => created_at }
    end
    let(:operation_receipt) do
      { "invoice_id" => 602, "operation_id" => "b5e2c1d0-4f3a-4b2c-8d1e-0f9a8b7c6d5e", "company_id" => 2, "kind" => "save",
        "invoice_state" => "draft", "entry_ids" => [240], "state" => "committed", "created_at" => created_at, "updated_at" => created_at }
    end
    let(:idempotency_receipt) do
      { "company_id" => 2, "key" => "web-2", "request_digest" => "d3", "status" => 201, "response" => { "entry" => { "id" => 240 } },
        "created_at" => created_at }
    end

    # What the prepared application holds: 101 released by a discarded draft
    # (F2) at version 2, and a new Copper Kettle entry 240 on a new draft.
    let(:recutover) do
      {
        "generation" => 3,
        "entries" => [entries[0], entries[1].merge("version" => 2, "locked" => false), entries[2], entry(id: 240, company_id: 2, locked: true)],
        "reservations" => [reservations[1], reservation(entry_id: 240, invoice_id: 602, company_id: 2)],
        "entry_audits" => [audit], "reservation_operations" => [operation_receipt], "idempotency_receipts" => [idempotency_receipt]
      }
    end

    def load(body = recutover) = request(:load_recutover_checkpoint, body:)

    def reconcile(body = recutover) = request(:reconcile_recutover_checkpoint, body:)

    def frozen_for_recutover!
      step(:close, 2)
      step(:freeze, 3)
    end

    it "loads while frozen under monolith: what it holds becomes the checkpoint as carried, and no snapshot is written" do
      frozen_for_recutover!

      loaded = load

      expect(loaded.status).to eq(200)
      expect(loaded.body).to eq(
        "entries" => 4, "reservations" => 2, "entry_audits" => 1, "reservation_operations" => 1, "idempotency_receipts" => 1
      )
      TimekeepingContracts.validate!(:handoff_api, "#/$defs/recutover_receipt", loaded.body)
      expect(fake.held).to eq(recutover.except("generation"))
      expect(fake.held.dig("entries", 0, "duration")).to eq(479.99999)
      expect(fake.outbox).to be_empty
      expect(fake.loaded).to be_nil
      expect(fake.copy).to eq(described_class::Copy.new(generation: 3, owner: "monolith", state: "frozen"))
    end

    it "answers the same when loaded again, holding the same" do
      frozen_for_recutover!
      first = load

      expect([load.status, load.body]).to eq([200, first.body])
      expect(fake.held).to eq(recutover.except("generation"))
      expect(fake.calls.map(&:operation).last(3)).to eq(%i[load_recutover_checkpoint] * 3)
    end

    it "gives back what it loaded when the next rollback takes it" do
      frozen_for_recutover!
      load
      step(:flip, 3)
      step(:close, 3)
      step(:freeze, 4)

      expect(take(4).body).to eq(recutover.merge("generation" => 4))
    end

    it "refuses the load anywhere but frozen under monolith at the checkpoint's generation, and changes nothing" do
      [[-> { nil }, 3], [-> { nil }, 2], [-> { step(:close, 2) }, 3], [-> { step(:freeze, 3) }, 2], [-> { nil }, 4]].each do |reach, carried|
        reach.call
        refused = load(recutover.merge("generation" => carried))

        expect([refused.status, refused.body["type"]]).to eq([409, type("out-of-step")]), "carried #{carried} at #{fake.copy.to_h}"
      end
      expect(fake.held.slice("entries", "reservations")).to eq("entries" => entries, "reservations" => reservations)
    end

    it "refuses the load under legacy and under timekeeping, naming the owner it expects" do
      { "legacy" => 0, "timekeeping" => 2 }.each do |owner, generation|
        other = described_class.new(generation:, owner:).install!
        step(:close, generation)
        step(:freeze, generation + 1)

        refused = load(recutover.merge("generation" => generation + 1))

        expect([refused.status, refused.body["type"]]).to eq([409, type("out-of-step")]), owner
        expect(refused.body["detail"]).to include("expects owner monolith, found owner #{owner}")
        expect(other.held).to eq(described_class::HELD.index_with { [] })
        expect(other.violations).to be_empty
      end
    end

    it "refuses a row no take could answer, listing each as RecutoverLoad does, and loads nothing" do
      frozen_for_recutover!
      provisional = recutover["reservations"].last.merge("state" => "provisional", "operation_id" => operation_receipt["operation_id"])

      refused = load(recutover.merge(
        "entries" => recutover["entries"].map { |carried| carried["id"] == 240 ? carried.except("duration") : carried },
        "reservations" => [recutover["reservations"].first, provisional],
        "entry_audits" => [audit.merge("action" => "rewrite")],
        "reservation_operations" => [operation_receipt.merge("state" => "prepared")],
        "idempotency_receipts" => [idempotency_receipt.except("request_digest")]
      ))

      expect([refused.status, refused.body["type"]]).to eq([422, type("checkpoint-refused")])
      expect(refused.body["lists"]).to eq(
        "not_a_contract_entry" => [240], "provisional_reservation" => [240], "not_a_contract_audit" => [15],
        "not_a_terminal_receipt" => ["602/b5e2c1d0-4f3a-4b2c-8d1e-0f9a8b7c6d5e"], "not_a_contract_idempotency_receipt" => ["2/web-2"]
      )
      expect(fake.held.slice("entries", "reservations")).to eq("entries" => entries, "reservations" => reservations)
      expect(fake.outbox).to be_empty
    end

    it "answers a scripted refusal of a checkpoint that would drop what it holds" do
      frozen_for_recutover!
      fake.fail_next(:load_recutover_checkpoint, status: 422, slug: "checkpoint-refused", lists: { "dropped_entry" => [205] })

      refused = load

      expect([refused.status, refused.body["lists"]]).to eq([422, { "dropped_entry" => [205] }])
      expect(fake.held.slice("entries", "reservations")).to eq("entries" => entries, "reservations" => reservations)
      expect(load.status).to eq(200)
    end

    it "records a body outside the request contract, loading nothing", :violates do
      frozen_for_recutover!

      [
        recutover.except("idempotency_receipts"),
        recutover.merge("payments" => []),
        recutover.merge("entries" => [entries.first.except("version")]),
        recutover.merge("entry_audits" => [audit.except("id")])
      ].each { |body| expect(load(body).status).to eq(400) }
      expect(request(:load_recutover_checkpoint, body: recutover, generation: 2).status).to eq(400)

      expect(fake.violations.size).to eq(5)
      expect(fake.held.slice("entries", "reservations")).to eq("entries" => entries, "reservations" => reservations)
    end

    it "reconciles what it loaded, in any order, answering the load's receipt and writing nothing" do
      frozen_for_recutover!
      loaded = load

      reconciled = reconcile(recutover.merge(described_class::HELD.index_with { |part| recutover[part].reverse }))

      expect([reconciled.status, reconciled.body]).to eq([200, loaded.body])
      TimekeepingContracts.validate!(:handoff_api, "#/$defs/recutover_receipt", reconciled.body)
      expect(fake.held).to eq(recutover.except("generation"))
      expect(fake.outbox).to be_empty
      expect(fake.copy).to eq(described_class::Copy.new(generation: 3, owner: "monolith", state: "frozen"))
    end

    it "lists, before a load, every part that differs from what it still holds from before the rollback" do
      frozen_for_recutover!

      refused = reconcile

      expect([refused.status, refused.body["type"], refused.body["retryable"]]).to eq([409, type("checkpoint-differs"), false])
      expect(refused.body["lists"]).to eq(
        "entry_missing" => [240], "entry_differs" => [101], "entry_audit_missing" => [15],
        "reservation_operation_missing" => ["602/b5e2c1d0-4f3a-4b2c-8d1e-0f9a8b7c6d5e"], "idempotency_receipt_missing" => ["2/web-2"],
        "reservations_differ" => [101, 240]
      )
      expect(fake.held.slice("entries", "reservations")).to eq("entries" => entries, "reservations" => reservations)
    end

    it "lists each row missing, unexpected or differing, by RecutoverReconcile's names, and changes nothing" do
      frozen_for_recutover!
      load
      other_receipt = operation_receipt.merge("invoice_id" => 603, "operation_id" => "0d4c3b2a-1f0e-4d9c-8b7a-6f5e4d3c2b1a", "state" => "aborted")
      fake.hold!(reservation_operations: [operation_receipt, other_receipt])

      refused = reconcile(recutover.merge(
        "entries" => [entries[0].merge("duration" => 479.9999900000001), *recutover["entries"].drop(1)],
        "reservations" => [reservations[1].merge("edit_lock" => true), recutover["reservations"].last],
        "entry_audits" => [audit, audit.merge("id" => 16)],
        "idempotency_receipts" => [idempotency_receipt.merge("status" => 200)]
      ))

      expect([refused.status, refused.body["type"]]).to eq([409, type("checkpoint-differs")])
      expect(refused.body["lists"]).to eq(
        "entry_differs" => [102], "entry_audit_missing" => [16], "reservation_operation_unexpected" => ["603/0d4c3b2a-1f0e-4d9c-8b7a-6f5e4d3c2b1a"],
        "idempotency_receipt_differs" => ["2/web-2"], "reservations_differ" => [102]
      )
      expect(fake.held.except("reservation_operations")).to eq(recutover.except("generation", "reservation_operations"))
    end

    it "refuses the reconcile anywhere but frozen under monolith at the checkpoint's generation" do
      [[-> { nil }, 3], [-> { nil }, 2], [-> { step(:close, 2) }, 3], [-> { step(:freeze, 3) }, 2], [-> { nil }, 4]].each do |reach, carried|
        reach.call
        refused = reconcile(recutover.merge("generation" => carried))

        expect([refused.status, refused.body["type"]]).to eq([409, type("out-of-step")]), "carried #{carried} at #{fake.copy.to_h}"
      end
      load
      step(:flip, 3)

      expect(reconcile.body["type"]).to eq(type("out-of-step"))
    end

    it "refuses the reconcile under legacy and under timekeeping, naming the owner it expects" do
      { "legacy" => 0, "timekeeping" => 2 }.each do |owner, generation|
        other = described_class.new(generation:, owner:).install!
        step(:close, generation)
        step(:freeze, generation + 1)

        refused = reconcile(recutover.merge("generation" => generation + 1))

        expect([refused.status, refused.body["type"]]).to eq([409, type("out-of-step")]), owner
        expect(refused.body["detail"]).to include("expects owner monolith, found owner #{owner}")
        expect(other.violations).to be_empty
      end
    end

    it "records a reconcile body outside the request contract", :violates do
      frozen_for_recutover!
      load

      [recutover.except("entry_audits"), recutover.merge("entries" => [entries.first.except("id")])].each do |body|
        expect(reconcile(body).status).to eq(400)
      end
      expect(request(:reconcile_recutover_checkpoint, body: recutover, generation: 2).status).to eq(400)

      expect(fake.violations.size).to eq(3)
      expect(fake.held).to eq(recutover.except("generation"))
    end
  end

  it "relays the loaded snapshots to the projection endpoint, after which the outbox is drained" do
    company = create(:company)
    client = create(:client, company:)
    project = create(:project, client:)
    user = create(:user)
    stored = create(:timesheet_entry, project:, user:, duration: 30.0)
    allow(Rails.configuration.x.timekeeping).to receive(:token_key).and_return(TimekeepingContracts::TEST_TOKEN_KEY)
    frozen!
    request(:load_checkpoint, body: {
      "generation" => 1,
      "entries" => [entry(id: stored.id, company_id: company.id, project_id: project.id, user_id: user.id, duration: 90.7, locked: true)],
      "reservations" => []
    })

    receipts = fake.relay!

    expect(receipts.size).to eq(1)
    expect(stored.reload).to have_attributes(version: 1, duration: 90.7, locked: true)
    expect(fake.undelivered).to be_empty
    expect(request(:read_handoff).body["outbox"]).to eq("latest_position" => 1, "undelivered" => 0)
  end

  describe "scripting" do
    it "answers a scripted problem instead of running, changing nothing" do
      fake.fail_next(:run_step, status: 503, slug: "drain-timeout", retryable: true)

      refused = step(:close, 0)

      expect([refused.status, refused.body["type"], refused.body["retryable"]]).to eq([503, type("drain-timeout"), true])
      expect(fake.copy.state).to eq("open")
      expect(step(:close, 0).status).to eq(200)
    end

    it "runs the call and then loses its response" do
      fake.lose_next_response(:run_step)

      expect { step(:close, 0) }.to raise_error(Faraday::TimeoutError)
      expect(fake.copy).to eq(described_class::Copy.new(generation: 1, owner: "legacy", state: "closed"))
    end
  end

  describe "what it refuses of a consumer" do
    it "refuses a missing, forged or expired token, a user token and the relay's", :violates do
      tokens = {
        missing: "",
        forged: handoff_token(key: "another-key"),
        relay: TimekeepingContracts.sign({ "sub" => "service:timekeeping-relay", "aud" => "projection" }),
        user: TimekeepingContracts.user_token(company_id: 1),
        expired: travel_to(2.minutes.ago) { handoff_token }
      }

      tokens.each do |name, token|
        refused = request(:read_handoff, token:)

        expect([refused.status, refused.body["type"]]).to eq([401, type("unauthenticated")]), name.to_s
      end
    end

    it "records a missing generation header, a generation unlike the body's, and a body outside the contract", :violates do
      expect(request(:run_step, step: "close", body: { "generation" => 0 }, without: ["X-Ownership-Generation"]).status).to eq(400)
      expect(request(:run_step, step: "close", body: { "generation" => 0 }, generation: 1).status).to eq(400)
      expect(request(:load_checkpoint, body: { "generation" => 1, "entries" => [] }).status).to eq(400)

      expect(fake.violations.size).to eq(3)
      expect(fake.copy.state).to eq("open")
    end
  end

  it "leaves every other Timekeeping path to FakeTimekeeping" do
    TimekeepingContracts::FakeTimekeeping.new(generation: 1).install!

    expect(request(:read_handoff).status).to eq(200)
    expect(fake.calls.size).to eq(1)
  end
end
