# frozen_string_literal: true

# The duplicate and reordered delivery of docs/architecture/timekeeping-soa.md
# §13 item 6, sent on purpose: named entries' outbox snapshots resent to the
# projection consumer out of order, and twice, through the relay's own
# delivery (OutboxRelay#redeliver), each send checked against the receipt the
# consumer must answer, since it upserts by (entry_id, version) and ignores
# anything not newer (§5.4):
#
#   newest  each entry's latest snapshot, all in one batch: every one applied,
#           so the projection held none of them yet
#   older   each older snapshot on its own, newest first: each ignored
#   again   every snapshot of those entries, in outbox order, in one batch:
#           every one ignored
#
# Run it while the relay is stopped, after the entries changed: the
# projection is then behind on every one of them. It reads the outbox and
# marks nothing, so once the relay runs again it still delivers what it had
# not delivered, and the consumer gets those snapshots a second time.
#
# It runs only while this copy says Timekeeping owns the entries with
# admission open, since only then is this outbox what the projection
# follows. It refuses an entry it does not hold, or one with fewer than two
# snapshots, which cannot be sent out of order. The first receipt that is not
# the expected one raises Unexpected; what was sent before it stays sent.
class OutboxRedelivery
  class Error < StandardError; end

  # Nothing was sent.
  class Refused < Error; end

  # The consumer answered a receipt other than the one it must answer.
  class Unexpected < Error; end

  # One batch sent: which step, which (entry id, version) pairs, the receipt.
  Sent = Data.define(:step, :snapshots, :receipt) do
    def summary = snapshots.map { |entry_id, version| "#{entry_id}@#{version}" }.join(" ")
  end

  def initialize(entry_ids:, relay: OutboxRelay.new)
    @entry_ids = entry_ids.uniq
    @relay = relay
  end

  # Sends every batch in order, yielding each Sent once its receipt checks
  # out. Answers them all.
  def call
    batches.map do |step, rows, expected|
      sent = Sent.new(step:, snapshots: rows.map { |row| [row.entry_id, row.version] }, receipt: @relay.redeliver(rows))
      check!(sent, expected)
      yield sent if block_given?
      sent
    end
  end

  private

    # [step, rows, expected receipt] for each batch, in the order sent.
    def batches
      histories = load_histories
      newest = histories.map(&:last)
      older = histories.flat_map { |rows| rows[0...-1].reverse }
      again = histories.flatten.sort_by(&:id)

      [[:newest, newest, { "applied" => newest.size, "ignored" => 0 }]] +
        older.map { |row| [:older, [row], { "applied" => 0, "ignored" => 1 }] } +
        [[:again, again, { "applied" => 0, "ignored" => again.size }]]
    end

    # Each entry's snapshots, oldest first, in the order the entries were named.
    def load_histories
      refuse! "name at least one entry" if @entry_ids.empty?
      ownership = Ownership.current
      unless ownership.owner_timekeeping? && ownership.state_open?
        refuse! "a redelivery runs while Timekeeping owns the entries with admission open; this copy says #{ownership.summary}"
      end

      rows = OutboxSnapshot.where(entry_id: @entry_ids).order(:id).group_by(&:entry_id)
      @entry_ids.map do |id|
        history = rows.fetch(id) { refuse! "Timekeeping's outbox holds no snapshot of entry #{id}" }
        refuse! "entry #{id} has #{history.size} snapshot in the outbox, and a redelivery needs two to reorder" if history.size < 2

        history
      end
    end

    def check!(sent, expected)
      receipt = sent.receipt.slice("applied", "ignored")
      return if receipt == expected

      raise Unexpected, "the consumer answered #{receipt} to the #{sent.step} batch (#{sent.summary}), not #{expected}#{why(sent.step)}"
    end

    def why(step)
      case step
      when :newest then ": it already held one of these entries at its latest version, so the relay was not stopped before the entries changed"
      else ": it applied a snapshot that is not newer than the one it holds"
      end
    end

    def refuse!(message) = raise(Refused, message)
end
