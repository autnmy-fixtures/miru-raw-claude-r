# frozen_string_literal: true

require "rails_helper"

# Timekeeping's side of the handoff procedure over the handoff API
# (handoff_api.json; docs/architecture/timekeeping-soa.md §10.5), against its
# consumer-side fake, which checks every request against the contract
# (§12.3).
RSpec.describe Timekeeping::HandoffClient do
  subject(:client) { described_class.new(url: TimekeepingContracts::FakeHandoff::URL, token_key: TimekeepingContracts::TEST_TOKEN_KEY) }

  let!(:fake) { TimekeepingContracts::FakeHandoff.new.install! }

  def entry(id:, company_id:, **fields)
    TimekeepingContracts::ENTRY_DEFAULTS.merge(
      "id" => id, "company_id" => company_id, "version" => 1, "project_id" => 10 + company_id, "user_id" => 7,
      "duration" => 90.7, "work_date" => "2026-11-02",
      "created_at" => "2026-11-02T09:15:30.123456Z", "updated_at" => "2026-11-03T17:45:01.654321Z"
    ).merge(fields.transform_keys(&:to_s))
  end

  def reservation(entry_id:, invoice_id:, company_id:, disposition: :active, edit_lock: true)
    TimekeepingReservations::Reservation.new(
      entry_id:, invoice_id:, company_id:, operation_id: nil, state: :committed, disposition:, edit_lock:
    )
  end

  # What Timekeeping::LegacyCheckpoint takes: entries in contract form, and
  # reservations as the shared rule's values, on two tenants.
  let(:checkpoint) do
    Timekeeping::LegacyCheckpoint::Checkpoint.new(
      generation: 1,
      entries: [
        entry(id: 101, company_id: 1, locked: true, duration: 0.1),
        entry(id: 102, company_id: 1, duration: 479.99999, source_metadata: { "skipped" => [nil] }),
        entry(id: 103, company_id: 1, locked: true, bill_status: "billed"),
        entry(id: 205, company_id: 2, discarded_at: "2026-11-04T08:00:00.000001Z")
      ],
      reservations: [
        reservation(entry_id: 101, invoice_id: 501, company_id: 1),
        reservation(entry_id: 102, invoice_id: 502, company_id: 1, edit_lock: false),
        reservation(entry_id: 103, invoice_id: 503, company_id: 1, disposition: :retained)
      ]
    )
  end

  let(:created_at) { "2026-11-02T09:15:30.123456Z" }

  # What Timekeeping holds on two tenants after the cutover and some writes,
  # in the contract's form: an entry on a kept draft at version 3, an
  # unlocked link, a destroyed non-draft's retained entry (§7.3), a discarded
  # entry, and an agent's entry whose metadata holds a null inside an array;
  # their audit rows, a committed receipt and the no-op abort (§9.3), and an
  # idempotency receipt per tenant under one key.
  let(:held) do
    {
      entries: [
        entry(id: 101, company_id: 1, version: 3, locked: true, duration: 0.1, note: "Kitchen prep"),
        entry(id: 102, company_id: 1, duration: 479.99999, note: nil),
        entry(id: 103, company_id: 1, version: 2, locked: true, bill_status: "billed"),
        entry(id: 104, company_id: 1, discarded_at: "2026-11-04T08:00:00.000001Z"),
        entry(id: 230, company_id: 2, version: 5, locked: true, agent_id: 4, source: "mcp", proof_metadata: { "tags" => [nil, "a"] })
      ],
      reservations: [
        wire(reservation(entry_id: 101, invoice_id: 501, company_id: 1)),
        wire(reservation(entry_id: 102, invoice_id: 502, company_id: 1, edit_lock: false)),
        wire(reservation(entry_id: 103, invoice_id: 503, company_id: 1, disposition: :retained)),
        wire(reservation(entry_id: 230, invoice_id: 601, company_id: 2))
      ],
      entry_audits: [
        { "id" => 9, "entry_id" => 101, "company_id" => 1, "version" => 1, "action" => "create", "actor" => "user:7", "agent_id" => nil,
          "writer" => "web", "request_id" => "req-1", "audited_changes" => { "duration" => 0.1, "note" => nil }, "created_at" => created_at },
        { "id" => 14, "entry_id" => 230, "company_id" => 2, "version" => 5, "action" => "update", "actor" => "agent:4", "agent_id" => 4,
          "writer" => "agent", "request_id" => "req-2", "audited_changes" => { "note" => [nil, "Proofing"] }, "created_at" => created_at }
      ],
      reservation_operations: [
        { "invoice_id" => 501, "operation_id" => "3c9d1f6e-8a2b-4c5d-9e0f-1a2b3c4d5e6f", "company_id" => 1, "kind" => "save",
          "invoice_state" => "draft", "entry_ids" => [101], "state" => "committed", "created_at" => created_at, "updated_at" => created_at },
        { "invoice_id" => 701, "operation_id" => "8f14e45f-ceea-467f-a0e3-b4a1c3d2e5f6", "company_id" => nil, "kind" => nil,
          "invoice_state" => nil, "entry_ids" => [], "state" => "aborted", "created_at" => created_at, "updated_at" => created_at }
      ],
      idempotency_receipts: [
        { "company_id" => 1, "key" => "web-1", "request_digest" => "d1", "status" => 201,
          "response" => { "entry" => { "id" => 101, "duration" => 0.1 } }, "created_at" => created_at },
        { "company_id" => 2, "key" => "web-1", "request_digest" => "d2", "status" => 200, "response" => { "discarded_ids" => [] }, "created_at" => created_at }
      ]
    }
  end

  def wire(reservation)
    reservation.to_h.transform_keys(&:to_s).merge("state" => reservation.state.to_s, "disposition" => reservation.disposition.to_s)
  end

  def frozen!
    client.run_step(:close, generation: 0)
    client.run_step(:freeze, generation: 1)
  end

  after { expect(fake.violations).to be_empty }

  it "reads Timekeeping's copy of the ownership record and where its relay stands" do
    expect(client.status).to eq(described_class::Status.new(
      copy: described_class::Copy.new(generation: 0, owner: "legacy", state: "open"),
      outbox: described_class::Outbox.new(latest_position: nil, undelivered: 0)
    ))
    expect(client.status.outbox).to be_drained
  end

  it "runs each step at the generation it expects and answers the copy as the step left it" do
    expect(client.run_step(:close, generation: 0).copy).to eq(described_class::Copy.new(generation: 1, owner: "legacy", state: "closed"))
    expect(client.run_step("freeze", generation: 1).copy.state).to eq("frozen")
    expect(client.run_step(:flip, generation: 1).copy).to eq(described_class::Copy.new(generation: 1, owner: "timekeeping", state: "open"))
    expect(fake.calls.map { |call| [call.params, call.input] }).to eq([
      [{ "step" => "close" }, { "generation" => 0 }],
      [{ "step" => "freeze" }, { "generation" => 1 }],
      [{ "step" => "flip" }, { "generation" => 1 }]
    ])
  end

  it "aborts a handoff, keeping the raised generation" do
    client.run_step(:close, generation: 0)

    expect(client.run_step(:abort, generation: 1).copy).to eq(described_class::Copy.new(generation: 1, owner: "legacy", state: "open"))
  end

  it "raises Timekeeping's out-of-step refusal of a replayed step" do
    client.run_step(:close, generation: 0)

    expect { client.run_step(:close, generation: 0) }.to raise_error(described_class::Problem) { |problem|
      expect([problem.status, problem.type, problem.retryable]).to eq([409, "out-of-step", false])
    }
    expect(fake.copy.state).to eq("closed")
  end

  it "raises a retryable drain-timeout as its problem" do
    fake.fail_next(:run_step, status: 503, slug: "drain-timeout", retryable: true)

    expect { client.run_step(:close, generation: 0) }.to raise_error(described_class::Problem) { |problem|
      expect([problem.status, problem.type, problem.retryable]).to eq([503, "drain-timeout", true])
    }
  end

  it "refuses a step outside the contract without sending it" do
    expect { client.run_step(:settle, generation: 0) }.to raise_error(described_class::Invalid, /settle is not a step/)
    expect(fake.calls).to be_empty
  end

  describe "#load_checkpoint" do
    it "carries the checkpoint as taken and answers what Timekeeping loaded" do
      frozen!

      receipt = client.load_checkpoint(checkpoint, request_id: "handoff-7")

      expect(receipt).to eq(described_class::Receipt.new(entries: 4, reservations: 3))
      expect(fake.loaded["entries"]).to eq(checkpoint.entries)
      expect(fake.loaded["entries"].pluck("duration")).to eq([0.1, 479.99999, 90.7, 90.7])
      expect(fake.loaded.dig("entries", 1, "source_metadata")).to eq("skipped" => [nil])
      expect(fake.loaded["reservations"]).to include(
        "entry_id" => 103, "invoice_id" => 503, "company_id" => 1, "operation_id" => nil,
        "state" => "committed", "disposition" => "retained", "edit_lock" => true
      )
      expect(fake.calls.last.request_id).to eq("handoff-7")
      expect(client.status.outbox).to eq(described_class::Outbox.new(latest_position: 4, undelivered: 4))
    end

    it "raises already-loaded on a second load" do
      frozen!
      client.load_checkpoint(checkpoint)

      expect { client.load_checkpoint(checkpoint) }.to raise_error(described_class::Problem) { |problem|
        expect([problem.status, problem.type]).to eq([409, "already-loaded"])
      }
    end

    it "raises checkpoint-refused with its lists" do
      frozen!
      fake.fail_next(:load_checkpoint, status: 422, slug: "checkpoint-refused", lists: { "provisional_reservation" => [101] })

      expect { client.load_checkpoint(checkpoint) }.to raise_error(described_class::Problem) { |problem|
        expect([problem.status, problem.type, problem.lists]).to eq([422, "checkpoint-refused", { "provisional_reservation" => [101] }])
      }
      expect(fake.loaded).to be_nil
    end

    it "refuses a checkpoint the contract cannot carry without sending it" do
      broken = checkpoint.with(reservations: [reservation(entry_id: 101, invoice_id: 501, company_id: 1).with(state: :pending)])

      expect { client.load_checkpoint(broken) }.to raise_error(described_class::Invalid, /state/)
      expect(fake.calls).to be_empty
    end
  end

  describe "#reconcile_checkpoint" do
    it "answers what Timekeeping reconciled when it holds exactly the checkpoint" do
      frozen!
      client.load_checkpoint(checkpoint)

      expect(client.reconcile_checkpoint(checkpoint)).to eq(described_class::Receipt.new(entries: 4, reservations: 3))
    end

    it "raises checkpoint-differs with what each failed check found" do
      frozen!
      client.load_checkpoint(checkpoint)
      changed = checkpoint.with(entries: checkpoint.entries.map { |carried| carried["id"] == 102 ? carried.merge("duration" => 479.9999900000001) : carried })

      expect { client.reconcile_checkpoint(changed) }.to raise_error(described_class::Problem) { |problem|
        expect([problem.status, problem.type, problem.lists]).to eq([409, "checkpoint-differs", { "entry_differs" => [102] }])
      }
    end
  end

  describe "#take_checkpoint" do
    # Timekeeping owns the entries after a cutover at generation 1; the
    # rollback's close raises the generation to 2 and freezes there.
    let!(:fake) { TimekeepingContracts::FakeHandoff.new(generation: 1, owner: "timekeeping").install! }

    def frozen_for_rollback!
      fake.hold!(**held)
      client.run_step(:close, generation: 1)
      client.run_step(:freeze, generation: 2)
    end

    it "answers the checkpoint Timekeeping holds, every value exactly as carried" do
      frozen_for_rollback!

      taken = client.take_checkpoint(generation: 2)

      expect(taken).to be_a(described_class::TakenCheckpoint)
      expect(taken.generation).to eq(2)
      expect(taken.entries).to eq(held[:entries])
      expect(taken.entries.map { |carried| carried.values_at("id", "version", "duration", "locked") }).to eq(
        [[101, 3, 0.1, true], [102, 1, 479.99999, false], [103, 2, 90.7, true], [104, 1, 90.7, false], [230, 5, 90.7, true]]
      )
      expect(taken.entries.last["proof_metadata"]).to eq("tags" => [nil, "a"])
      expect(taken.entries[1]["note"]).to be_nil
      expect(taken.entries[3]["discarded_at"]).to eq("2026-11-04T08:00:00.000001Z")
      expect(taken.entry_audits).to eq(held[:entry_audits])
      expect(taken.reservation_operations).to eq(held[:reservation_operations])
      expect(taken.idempotency_receipts).to eq(held[:idempotency_receipts])
    end

    it "answers the reservations as the shared rule's values, the retained one with its own owner" do
      frozen_for_rollback!

      reservations = client.take_checkpoint(generation: 2).reservations

      expect(reservations).to all(be_a(TimekeepingReservations::Reservation))
      expect(reservations).to eq([
        reservation(entry_id: 101, invoice_id: 501, company_id: 1),
        reservation(entry_id: 102, invoice_id: 502, company_id: 1, edit_lock: false),
        reservation(entry_id: 103, invoice_id: 503, company_id: 1, disposition: :retained),
        reservation(entry_id: 230, invoice_id: 601, company_id: 2)
      ])
    end

    it "names the ids the incoming owner's entry and audit sequences are set above (§10.3)" do
      frozen_for_rollback!

      taken = client.take_checkpoint(generation: 2)

      expect([taken.highest_entry_id, taken.highest_entry_audit_id]).to eq([230, 14])
    end

    it "names no highest id when Timekeeping holds nothing" do
      client.run_step(:close, generation: 1)
      client.run_step(:freeze, generation: 2)

      taken = client.take_checkpoint(generation: 2)

      expect([taken.entries, taken.reservations, taken.entry_audits]).to eq([[], [], []])
      expect([taken.highest_entry_id, taken.highest_entry_audit_id]).to eq([nil, nil])
    end

    it "is a read: the generation goes in the query, no X-Ownership-Generation, and asking again answers the same" do
      frozen_for_rollback!

      first = client.take_checkpoint(generation: 2)

      expect(client.take_checkpoint(generation: 2)).to eq(first)
      expect(fake.calls.last(2).map { |call| [call.operation, call.input] }).to eq([[:take_checkpoint, { "generation" => "2" }]] * 2)
      expect(a_request(:get, "#{TimekeepingContracts::FakeHandoff::URL}/internal/v1/handoff/checkpoint?generation=2")
        .with { |request| !request.headers.key?("X-Ownership-Generation") && request.headers.key?("X-Request-Id") }).to have_been_made.twice
      expect(fake.copy).to eq(TimekeepingContracts::FakeHandoff::Copy.new(generation: 2, owner: "timekeeping", state: "frozen"))
      expect(fake.outbox).to be_empty
    end

    it "raises Timekeeping's out-of-step refusal anywhere but frozen under timekeeping at the generation asked" do
      fake.hold!(**held)
      refusals = {
        "open" => -> { },
        "closed" => -> { client.run_step(:close, generation: 1) },
        "frozen, asked another generation" => -> { client.run_step(:freeze, generation: 2) }
      }

      refusals.each do |where, reach|
        reach.call
        asked = where.include?("another") ? 3 : 2

        expect { client.take_checkpoint(generation: asked) }.to raise_error(described_class::Problem) { |problem|
          expect([problem.status, problem.type, problem.retryable]).to eq([409, "out-of-step", false]), where
        }
      end
    end

    it "raises out-of-step for a first cutover's copy, frozen under legacy" do
      legacy = TimekeepingContracts::FakeHandoff.new.install!
      client.run_step(:close, generation: 0)
      client.run_step(:freeze, generation: 1)

      expect { client.take_checkpoint(generation: 1) }.to raise_error(described_class::Problem, /409 out-of-step.*expects owner timekeeping/)
      expect(legacy.calls.last.operation).to eq(:take_checkpoint)
    end

    it "raises checkpoint-unsettled with what settle left unresolved, not retryable" do
      frozen_for_rollback!
      fake.fail_next(:take_checkpoint, status: 409, slug: "checkpoint-unsettled",
        lists: { "provisional_reservation" => [101], "unresolved_operation" => ["501/3c9d1f6e-8a2b-4c5d-9e0f-1a2b3c4d5e6f"] })

      expect { client.take_checkpoint(generation: 2) }.to raise_error(described_class::Problem) { |problem|
        expect([problem.status, problem.type, problem.retryable]).to eq([409, "checkpoint-unsettled", false])
        expect(problem.lists).to eq(
          "provisional_reservation" => [101], "unresolved_operation" => ["501/3c9d1f6e-8a2b-4c5d-9e0f-1a2b3c4d5e6f"]
        )
      }
    end

    it "refuses a generation the contract cannot carry without sending it" do
      [-1, nil, 1.5].each do |generation|
        expect { client.take_checkpoint(generation:) }.to raise_error(described_class::Invalid, /take_checkpoint/), generation.inspect
      end
      expect(fake.calls).to be_empty
    end

    it "raises Unavailable on a lost response; the take wrote nothing, so the tool asks again" do
      frozen_for_rollback!
      fake.lose_next_response(:take_checkpoint)

      expect { client.take_checkpoint(generation: 2) }.to raise_error(described_class::Unavailable, /take_checkpoint/)
      expect(client.take_checkpoint(generation: 2).entries).to eq(held[:entries])
    end

    it "raises ContractViolation on a checkpoint outside the contract, such as a provisional reservation" do
      provisional = wire(reservation(entry_id: 101, invoice_id: 501, company_id: 1)).merge("state" => "provisional")
      stub_request(:get, "#{TimekeepingContracts::FakeHandoff::URL}/internal/v1/handoff/checkpoint?generation=2").to_return(
        status: 200, headers: { "Content-Type" => "application/json" },
        body: JSON.generate({ "generation" => 2, **held.transform_keys(&:to_s), "reservations" => [provisional] })
      )

      expect { client.take_checkpoint(generation: 2) }.to raise_error(described_class::ContractViolation)
    end
  end

  describe "#load_recutover_checkpoint" do
    # The prepared application owns the entries after a rollback at
    # generation 2; the re-cutover's close raises the generation to 3 and
    # freezes there. Timekeeping still holds what it held at the rollback.
    let!(:fake) { TimekeepingContracts::FakeHandoff.new(generation: 2, owner: "monolith").install!.hold!(**held) }

    # What Timekeeping::LocalCheckpoint takes out of the prepared
    # application: what Timekeeping held, plus what the monolith owner
    # accepted after the rollback. 101 was released by a discarded draft (F2)
    # at version 4, and Copper Kettle logged 240 onto a new draft, with its
    # audit row, receipt and idempotency receipt.
    let(:checkpoint) do
      Timekeeping::LocalCheckpoint::Checkpoint.new(
        generation: 3,
        entries: held[:entries].map { |held_entry| held_entry["id"] == 101 ? held_entry.merge("version" => 4, "locked" => false) : held_entry } +
          [entry(id: 240, company_id: 2, locked: true, duration: 45.5, source_metadata: { "skipped" => [nil] })],
        reservations: [
          reservation(entry_id: 102, invoice_id: 502, company_id: 1, edit_lock: false),
          reservation(entry_id: 103, invoice_id: 503, company_id: 1, disposition: :retained),
          reservation(entry_id: 230, invoice_id: 601, company_id: 2),
          reservation(entry_id: 240, invoice_id: 602, company_id: 2)
        ],
        entry_audits: held[:entry_audits] + [
          { "id" => 15, "entry_id" => 240, "company_id" => 2, "version" => 1, "action" => "create", "actor" => "user:8", "agent_id" => nil,
            "writer" => "web", "request_id" => "req-3", "audited_changes" => { "duration" => 45.5 }, "created_at" => created_at }
        ],
        reservation_operations: held[:reservation_operations] + [
          { "invoice_id" => 602, "operation_id" => "b5e2c1d0-4f3a-4b2c-8d1e-0f9a8b7c6d5e", "company_id" => 2, "kind" => "save",
            "invoice_state" => "draft", "entry_ids" => [240], "state" => "committed", "created_at" => created_at, "updated_at" => created_at }
        ],
        idempotency_receipts: held[:idempotency_receipts] + [
          { "company_id" => 2, "key" => "web-2", "request_digest" => "d3", "status" => 201,
            "response" => { "entry" => { "id" => 240, "duration" => 45.5 } }, "created_at" => created_at }
        ]
      )
    end

    # The checkpoint as the wire carries it, part by part.
    def carried(checkpoint)
      {
        "entries" => checkpoint.entries, "reservations" => checkpoint.reservations.map { |carried| wire(carried) },
        "entry_audits" => checkpoint.entry_audits, "reservation_operations" => checkpoint.reservation_operations,
        "idempotency_receipts" => checkpoint.idempotency_receipts
      }
    end

    def frozen_for_recutover!
      client.run_step(:close, generation: 2)
      client.run_step(:freeze, generation: 3)
    end

    it "carries every part exactly as taken and answers how many rows of each Timekeeping loaded" do
      frozen_for_recutover!

      receipt = client.load_recutover_checkpoint(checkpoint)

      expect(receipt).to eq(described_class::RecutoverReceipt.new(
        entries: 6, reservations: 4, entry_audits: 3, reservation_operations: 3, idempotency_receipts: 3
      ))
      expect(fake.held).to eq(carried(checkpoint))
      expect(fake.held.fetch("entries").map { |held_entry| held_entry.values_at("id", "version", "duration", "locked") }).to eq(
        [[101, 4, 0.1, false], [102, 1, 479.99999, false], [103, 2, 90.7, true], [104, 1, 90.7, false], [230, 5, 90.7, true], [240, 1, 45.5, true]]
      )
      expect(fake.held.dig("entries", 4, "proof_metadata")).to eq("tags" => [nil, "a"])
      expect(fake.held.dig("entries", 5, "source_metadata")).to eq("skipped" => [nil])
      expect(fake.held.dig("entries", 3, "discarded_at")).to eq("2026-11-04T08:00:00.000001Z")
      expect(fake.held.fetch("reservations")).to include(
        "entry_id" => 103, "invoice_id" => 503, "company_id" => 1, "operation_id" => nil,
        "state" => "committed", "disposition" => "retained", "edit_lock" => true
      )
    end

    it "carries the generation in X-Ownership-Generation and the body, and Timekeeping writes no outbox snapshot" do
      frozen_for_recutover!

      client.load_recutover_checkpoint(checkpoint)

      expect(fake.calls.last).to have_attributes(operation: :load_recutover_checkpoint)
      expect(fake.calls.last.input.fetch("generation")).to eq(3)
      expect(a_request(:post, "#{TimekeepingContracts::FakeHandoff::URL}/internal/v1/handoff/recutover/checkpoint")
        .with(headers: { "X-Ownership-Generation" => "3" })).to have_been_made.once
      expect(client.status).to eq(described_class::Status.new(
        copy: described_class::Copy.new(generation: 3, owner: "monolith", state: "frozen"),
        outbox: described_class::Outbox.new(latest_position: nil, undelivered: 0)
      ))
    end

    it "may be sent again: Timekeeping holds the same and answers the same" do
      frozen_for_recutover!
      first = client.load_recutover_checkpoint(checkpoint)

      expect(client.load_recutover_checkpoint(checkpoint)).to eq(first)
      expect(fake.held).to eq(carried(checkpoint))
    end

    it "carries back what the rollback took, and after the flip Timekeeping gives it back again (§13 item 3)" do
      rolled_back = TimekeepingContracts::FakeHandoff.new(generation: 1, owner: "timekeeping").install!.hold!(**held)
      client.run_step(:close, generation: 1)
      client.run_step(:freeze, generation: 2)
      taken = client.take_checkpoint(generation: 2)
      client.run_step(:flip, generation: 2)
      client.run_step(:close, generation: 2)
      client.run_step(:freeze, generation: 3)

      client.load_recutover_checkpoint(taken.with(generation: 3))
      client.run_step(:flip, generation: 3)
      client.run_step(:close, generation: 3)
      client.run_step(:freeze, generation: 4)

      expect(client.take_checkpoint(generation: 4)).to eq(taken.with(generation: 4))
      expect(rolled_back.violations).to be_empty
    end

    it "raises Timekeeping's out-of-step refusal anywhere but frozen under monolith at the checkpoint's generation" do
      refusals = {
        "open" => -> { },
        "closed" => -> { client.run_step(:close, generation: 2) },
        "frozen, carried another generation" => -> { client.run_step(:freeze, generation: 3) }
      }

      refusals.each do |where, reach|
        reach.call
        carrying = where.include?("another") ? checkpoint.with(generation: 4) : checkpoint

        expect { client.load_recutover_checkpoint(carrying) }.to raise_error(described_class::Problem) { |problem|
          expect([problem.status, problem.type, problem.retryable]).to eq([409, "out-of-step", false]), where
        }
      end
      expect(fake.held).to eq(held.transform_keys(&:to_s))
    end

    it "raises out-of-step for a rollback's copy, frozen under timekeeping" do
      rollback = TimekeepingContracts::FakeHandoff.new(generation: 2, owner: "timekeeping").install!
      frozen_for_recutover!

      expect { client.load_recutover_checkpoint(checkpoint) }.to raise_error(described_class::Problem, /409 out-of-step.*expects owner monolith/)
      expect(rollback.calls.last.operation).to eq(:load_recutover_checkpoint)
    end

    it "raises checkpoint-refused with its lists when the checkpoint would drop a write Timekeeping holds" do
      frozen_for_recutover!
      fake.fail_next(:load_recutover_checkpoint, status: 422, slug: "checkpoint-refused",
        lists: { "dropped_entry" => [104], "dropped_idempotency_receipt" => ["1/web-1"] })

      expect { client.load_recutover_checkpoint(checkpoint) }.to raise_error(described_class::Problem) { |problem|
        expect([problem.status, problem.type, problem.retryable]).to eq([422, "checkpoint-refused", false])
        expect(problem.lists).to eq("dropped_entry" => [104], "dropped_idempotency_receipt" => ["1/web-1"])
      }
      expect(fake.held).to eq(held.transform_keys(&:to_s))
    end

    it "raises checkpoint-refused for a provisional reservation, which the request may carry but no take answers" do
      frozen_for_recutover!
      provisional = checkpoint.reservations.last.with(state: :provisional, operation_id: "b5e2c1d0-4f3a-4b2c-8d1e-0f9a8b7c6d5e")

      expect { client.load_recutover_checkpoint(checkpoint.with(reservations: checkpoint.reservations[0..-2] + [provisional])) }
        .to raise_error(described_class::Problem) { |problem|
          expect([problem.status, problem.type, problem.lists]).to eq([422, "checkpoint-refused", { "provisional_reservation" => [240] }])
        }
      expect(fake.held).to eq(held.transform_keys(&:to_s))
    end

    it "refuses a checkpoint the contract cannot carry without sending it" do
      broken = {
        "a reservation in no state of the rule" =>
          checkpoint.with(reservations: [reservation(entry_id: 240, invoice_id: 602, company_id: 2).with(state: :pending)]),
        "an entry without its version" => checkpoint.with(entries: [checkpoint.entries.last.except("version")]),
        "an audit row without its id" => checkpoint.with(entry_audits: [checkpoint.entry_audits.last.except("id")]),
        "a receipt without its operation" => checkpoint.with(reservation_operations: [checkpoint.reservation_operations.last.except("operation_id")]),
        "an idempotency receipt without its key" => checkpoint.with(idempotency_receipts: [checkpoint.idempotency_receipts.last.except("key")])
      }

      broken.each do |what, carrying|
        expect { client.load_recutover_checkpoint(carrying) }.to raise_error(described_class::Invalid, /load_recutover_checkpoint/), what
      end
      expect(fake.calls).to be_empty
    end

    it "raises Unavailable on a lost response, though the load ran; sending it again answers the same" do
      frozen_for_recutover!
      fake.lose_next_response(:load_recutover_checkpoint)

      expect { client.load_recutover_checkpoint(checkpoint) }.to raise_error(described_class::Unavailable, /load_recutover_checkpoint/)
      expect(fake.held).to eq(carried(checkpoint))
      expect(client.load_recutover_checkpoint(checkpoint).entries).to eq(6)
      expect(fake.held).to eq(carried(checkpoint))
    end

    it "raises ContractViolation on a receipt outside the contract" do
      stub_request(:post, "#{TimekeepingContracts::FakeHandoff::URL}/internal/v1/handoff/recutover/checkpoint").to_return(
        status: 200, headers: { "Content-Type" => "application/json" }, body: JSON.generate({ "entries" => 6, "reservations" => 4 })
      )

      expect { client.load_recutover_checkpoint(checkpoint) }.to raise_error(described_class::ContractViolation)
    end
  end

  describe "when Timekeeping cannot answer" do
    it "raises Unavailable on a lost response, though the step ran, so the tool reads the status again" do
      fake.lose_next_response(:run_step)

      expect { client.run_step(:close, generation: 0) }.to raise_error(described_class::Unavailable, /run_step/)
      expect(client.status.copy).to eq(described_class::Copy.new(generation: 1, owner: "legacy", state: "closed"))
    end

    it "raises Unavailable when Timekeeping is down or answers a 5xx that is not a problem" do
      stub_request(:get, "#{TimekeepingContracts::FakeHandoff::URL}/internal/v1/handoff").to_raise(Faraday::ConnectionFailed.new("refused"))
      expect { client.status }.to raise_error(described_class::Unavailable, /refused/)

      stub_request(:get, "#{TimekeepingContracts::FakeHandoff::URL}/internal/v1/handoff").to_return(status: 502, body: "Bad gateway")
      expect { client.status }.to raise_error(described_class::Unavailable, /HTTP 502/)
    end

    it "raises ContractViolation on an answer outside the contract" do
      stub_request(:get, "#{TimekeepingContracts::FakeHandoff::URL}/internal/v1/handoff")
        .to_return(status: 200, body: JSON.generate({ "ownership" => { "generation" => 0 } }), headers: { "Content-Type" => "application/json" })

      expect { client.status }.to raise_error(described_class::ContractViolation)
    end
  end

  it "waits longer than the request path's 2 s, for a step's 60 s lock timeout" do
    expect(client.send(:http).options.timeout).to be > Timekeeping::HandoffFence::DRAIN_TIMEOUT
    expect(client.send(:http).options.open_timeout).to eq(Timekeeping::InternalApi::TIMEOUT)
  end

  it "presents the handoff tool's service token, never a user token" do
    client.status
    claims = nil

    expect(a_request(:get, "#{TimekeepingContracts::FakeHandoff::URL}/internal/v1/handoff").with { |request|
      token = request.headers.fetch("Authorization").delete_prefix("Bearer ")
      claims = TimekeepingContracts.decode(token, key: TimekeepingContracts::TEST_TOKEN_KEY, audience: "handoff")
    }).to have_been_made
    expect(claims).to include("sub" => "service:timekeeping-handoff", "aud" => "handoff")
    expect(claims["exp"] - claims["iat"]).to eq(60)
  end

  it "is not configured without a URL or a token key" do
    expect { described_class.new(url: nil, token_key: "key") }.to raise_error(described_class::NotConfigured)
    expect { described_class.new(url: "http://timekeeping.test", token_key: nil) }.to raise_error(described_class::NotConfigured)
  end
end
