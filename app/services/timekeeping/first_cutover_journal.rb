# frozen_string_literal: true

# Where the first cutover's handoff tool (Timekeeping::FirstCutover) keeps
# what an interrupted run took, so a run in another process can resume it
# (docs/architecture/timekeeping-soa.md §10.5: "can resume from the step that
# failed"). It holds the run's Resume: the financial snapshot, the "before" of
# the money check (§13 item 2), and the one checkpoint (§10.5 step 4). The
# checkpoint must survive the process: once the load has run, a second one
# cannot be taken (FirstCutover), so without it the handoff could only be
# aborted.
#
# It is one JSON file. Each record replaces it whole, through a temporary
# file that is synced and then renamed over it, so a process that dies
# mid-write leaves the previous record, never half of one. The file holds
# every entry, so it is written for its owner only (0600). A file that is
# there but cannot be read back raises Unreadable: it is never taken for an
# empty journal, which would lose the checkpoint.
#
# Values round-trip exactly: the financial snapshot is plain strings, entries
# are already in their contract's JSON form (Timekeeping::StoredEntries), and
# a reservation's state and disposition are carried by name, as the handoff
# API carries them.
class Timekeeping::FirstCutoverJournal
  FORMAT = 1
  DEFAULT_PATH = "tmp/timekeeping/first_cutover.json"

  # The file is there, but is not a journal this code wrote.
  class Unreadable < StandardError; end

  attr_reader :path

  # A relative `path` is taken from the application's root.
  def initialize(path: DEFAULT_PATH)
    @path = Rails.root.join(path)
  end

  # What the last run recorded, or an empty Resume when nothing is recorded.
  def resume
    return Timekeeping::FirstCutover::Resume.new unless path.exist?

    self.class.load(JSON.parse(path.read))
  rescue JSON::ParserError, KeyError, TypeError, ArgumentError, NoMethodError => error
    raise Unreadable, "Timekeeping first cutover journal #{path} cannot be read (#{error.message}); it was left as it is"
  end

  def record(resume)
    path.dirname.mkpath
    temporary = path.sub_ext("#{path.extname}.tmp")
    File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
      file.write(JSON.generate(self.class.dump(resume)))
      file.fsync
    end
    File.rename(temporary, path)
    File.open(path.dirname, &:fsync)
  end

  # Forgets the record, once the handoff it belongs to has ended: cut over or
  # aborted.
  def clear = FileUtils.rm_f(path)

  def self.dump(resume)
    checkpoint = resume.checkpoint
    {
      "format" => FORMAT,
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
    raise KeyError, "format #{document.fetch('format').inspect}, expected #{FORMAT}" unless document.fetch("format") == FORMAT

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
