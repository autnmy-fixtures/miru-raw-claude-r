# frozen_string_literal: true

# Where the rollback's handoff tool (Timekeeping::Rollback) keeps what an
# interrupted run took, so a run in another process can resume it
# (docs/architecture/timekeeping-soa.md §10.5: "can resume from the step that
# failed"). It holds the run's Resume, which is only the financial snapshot:
# the "before" of the money check (§13 item 2), taken once close_local has
# drained the billing writes already admitted. The rollback keeps no
# checkpoint, because the take is a read of a frozen Timekeeping and can
# always be asked again. The file itself, written whole and for its owner
# only, is Timekeeping::HandoffJournal's.
#
# The document names the handoff it belongs to, so a first cutover's journal
# handed to the rollback by mistake is refused as Unreadable, never resumed.
class Timekeeping::RollbackJournal < Timekeeping::HandoffJournal
  NAME = "rollback"
  FORMAT = 1
  HANDOFF = "rollback"
  DEFAULT_PATH = "tmp/timekeeping/rollback.json"

  def self.empty = Timekeeping::Rollback::Resume.new

  def self.dump(resume) = { "handoff" => HANDOFF, "financial_snapshot" => resume.financial_snapshot }

  def self.load(document)
    handoff = document.fetch("handoff")
    raise KeyError, "handoff #{handoff.inspect}, expected #{HANDOFF.inspect}" unless handoff == HANDOFF

    Timekeeping::Rollback::Resume.new(financial_snapshot: document.fetch("financial_snapshot"))
  end
end
