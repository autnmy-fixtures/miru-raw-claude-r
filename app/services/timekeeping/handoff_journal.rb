# frozen_string_literal: true

# A handoff tool's journal kept in a file: what an interrupted run took, so a
# run in another process can resume it (docs/architecture/timekeeping-soa.md
# §10.5: "can resume from the step that failed"). Each handoff has its own
# kind, which names what it holds and how it reads back
# (Timekeeping::FirstCutoverJournal, Timekeeping::RollbackJournal,
# Timekeeping::RecutoverJournal); this is the file they share.
#
# It is one JSON file. Each record replaces it whole, through a temporary
# file that is synced and then renamed over it, so a process that dies
# mid-write leaves the previous record, never half of one. What a handoff
# takes is the business's own data, so the file is written for its owner
# only (0600). A file that is there but cannot be read back raises
# Unreadable: it is never taken for an empty journal, which would lose what
# the interrupted run took.
#
# A kind defines NAME (how its messages name it), FORMAT, and three class
# methods: `empty`, the resume of a run with nothing recorded; `dump(resume)`,
# the JSON document of a resume; `load(document)`, the resume of a document,
# raising KeyError, TypeError or ArgumentError on one it did not write.
class Timekeeping::HandoffJournal
  # The file is there, but is not a journal this code wrote.
  class Unreadable < StandardError; end

  attr_reader :path

  # A relative `path` is taken from the application's root.
  def initialize(path: self.class::DEFAULT_PATH)
    @path = Rails.root.join(path)
  end

  # What the last run recorded, or the empty resume when nothing is recorded.
  def resume
    kind = self.class
    return kind.empty unless path.exist?

    document = JSON.parse(path.read)
    format = document.fetch("format")
    raise KeyError, "format #{format.inspect}, expected #{kind::FORMAT}" unless format == kind::FORMAT

    kind.load(document)
  rescue JSON::ParserError, KeyError, TypeError, ArgumentError, NoMethodError => error
    raise Unreadable, "Timekeeping #{kind::NAME} journal #{path} cannot be read (#{error.message}); it was left as it is"
  end

  def record(resume)
    kind = self.class
    path.dirname.mkpath
    temporary = path.sub_ext("#{path.extname}.tmp")
    File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
      file.write(JSON.generate({ "format" => kind::FORMAT }.merge(kind.dump(resume))))
      file.fsync
    end
    File.rename(temporary, path)
    File.open(path.dirname, &:fsync)
  end

  # Forgets the record, once the handoff it belongs to has ended: done or
  # aborted.
  def clear = FileUtils.rm_f(path)
end
