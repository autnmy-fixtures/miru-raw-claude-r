# frozen_string_literal: true

# Where the first cutover's handoff tool (Timekeeping::FirstCutover) keeps
# what an interrupted run took, so a run in another process can resume it
# (docs/architecture/timekeeping-soa.md §10.5: "can resume from the step that
# failed"). It holds the run's Resume: the financial snapshot, the "before" of
# the money check (§13 item 2), and the one checkpoint (§10.5 step 4). The
# checkpoint must survive the process: once the load has run, a second one
# cannot be taken (FirstCutover), so without it the handoff could only be
# aborted. The file itself, written whole and for its owner only, is
# Timekeeping::HandoffJournal's.
#
# Values round-trip exactly: the financial snapshot is plain strings, entries
# are already in their contract's JSON form (Timekeeping::StoredEntries), and
# a reservation's state and disposition are carried by name, as the handoff
# API carries them.
class Timekeeping::FirstCutoverJournal < Timekeeping::HandoffJournal
  NAME = "first cutover"
  FORMAT = 1
  DEFAULT_PATH = "tmp/timekeeping/first_cutover.json"

  def self.empty = Timekeeping::FirstCutover::Resume.new

  def self.dump(resume)
    checkpoint = resume.checkpoint
    {
      "financial_snapshot" => resume.financial_snapshot,
      "checkpoint" => checkpoint && {
        "generation" => checkpoint.generation,
        "entries" => checkpoint.entries,
        "reservations" => checkpoint.reservations.map do |reservation|
          reservation.to_h.transform_keys(&:to_s).merge("state" => reservation.state&.to_s, "disposition" => reservation.disposition&.to_s)
        end
      }
    }
  end

  def self.load(document)
    checkpoint = document.fetch("checkpoint")
    Timekeeping::FirstCutover::Resume.new(
      financial_snapshot: document.fetch("financial_snapshot"),
      checkpoint: checkpoint && Timekeeping::LegacyCheckpoint::Checkpoint.new(
        generation: checkpoint.fetch("generation"),
        entries: checkpoint.fetch("entries"),
        reservations: checkpoint.fetch("reservations").map { |reservation| reservation_from(reservation) }
      )
    )
  end

  def self.reservation_from(fields)
    TimekeepingReservations::Reservation.new(
      **fields.symbolize_keys, state: fields.fetch("state")&.to_sym, disposition: fields.fetch("disposition")&.to_sym
    )
  end
  private_class_method :reservation_from
end
