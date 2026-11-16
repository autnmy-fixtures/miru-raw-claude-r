# frozen_string_literal: true

# The runner for the first cutover to Timekeeping (docs/architecture/
# timekeeping-soa.md §10.2 step 5, §10.5), for the local demo (§11.2). Each
# run is its own process: what an interrupted run took, the financial
# snapshot and the checkpoint, is kept in a journal file
# (Timekeeping::FirstCutoverJournal) and handed to the next run, which goes
# on from the step that did not commit.
#
#   bin/rails timekeeping:first_cutover        run, or resume, to the end
#   bin/rails timekeeping:first_cutover:abort  reopen admission on both copies
#
# Both read TIMEKEEPING_URL and TIMEKEEPING_TOKEN_KEY, as the handoff client
# does. JOURNAL names the journal file (tmp/timekeeping/first_cutover.json by
# default), DISPOSITION the recorded disposition of the unlocked links
# (§10.4; the seed disposition of the two seeded businesses by default).
#
# The runner for the rollback to the prepared application (§10.2 step 6,
# §10.5) works the same way, with its own journal
# (Timekeeping::RollbackJournal), which keeps the financial snapshot:
#
#   bin/rails timekeeping:rollback             run, or resume, to the end
#   bin/rails timekeeping:rollback:abort       reopen admission on both copies
#
# They read TIMEKEEPING_URL and TIMEKEEPING_TOKEN_KEY too, and JOURNAL
# (tmp/timekeeping/rollback.json by default). The rollback takes no
# disposition: its reservations come out of Timekeeping as Timekeeping holds
# them.
#
# The runner for the re-cutover from the prepared application back to
# Timekeeping (§10.2 step 6, §10.5) works the same way again, with its own
# journal (Timekeeping::RecutoverJournal), which keeps the financial snapshot:
#
#   bin/rails timekeeping:recutover            run, or resume, to the end
#   bin/rails timekeeping:recutover:abort      reopen admission on both copies
#
# They read TIMEKEEPING_URL and TIMEKEEPING_TOKEN_KEY too, and JOURNAL
# (tmp/timekeeping/recutover.json by default). The re-cutover takes no
# disposition either: its reservations come out of the prepared application
# as it holds them.
module TimekeepingFirstCutoverTask
  def self.journal = Timekeeping::FirstCutoverJournal.new(path: ENV.fetch("JOURNAL", Timekeeping::FirstCutoverJournal::DEFAULT_PATH))

  def self.logger = Logger.new($stdout, formatter: ->(_severity, _time, _progname, message) { "#{message}\n" })

  def self.resume_hint(journal)
    "Both copies stay where the run left them, and #{journal.path} keeps what it took. " \
      "Run bin/rails timekeeping:first_cutover again to resume, or bin/rails timekeeping:first_cutover:abort to reopen admission."
  end
end

namespace :timekeeping do
  desc "Run or resume the first cutover to Timekeeping (JOURNAL=path, DISPOSITION=path)"
  task first_cutover: :environment do
    journal = TimekeepingFirstCutoverTask.journal
    cutover = Timekeeping::FirstCutover.new(
      unlocked_link_invoice_ids: Timekeeping::RecordedDisposition.unlocked_link_invoice_ids(
        ENV.fetch("DISPOSITION", Timekeeping::RecordedDisposition::SEED)
      ),
      journal:, logger: TimekeepingFirstCutoverTask.logger
    )

    result = cutover.call
    journal.clear
    puts "Timekeeping first cutover: done at generation #{result.generation}, Timekeeping owns entries " \
      "(reconciled: #{result.entries || 'earlier'} entries, #{result.reservations || 'earlier'} reservations)"
  rescue Timekeeping::FirstCutover::Aborted => error
    journal.clear
    abort [error.message, *error.lists.map { |list, ids| "  #{list}: #{Array(ids).join(', ')}" }].join("\n")
  rescue Timekeeping::FirstCutover::Unresumable, Timekeeping::FirstCutoverJournal::Unreadable,
    Timekeeping::RecordedDisposition::Unresolved, Timekeeping::InternalApi::NotConfigured => error
    abort error.message
  rescue StandardError => error
    raise unless journal

    abort "Timekeeping first cutover stopped: #{error.class}: #{error.message}\n#{TimekeepingFirstCutoverTask.resume_hint(journal)}"
  end

  namespace :first_cutover do
    desc "Abort the first cutover in progress, reopening admission on both copies (JOURNAL=path)"
    task abort: :environment do
      journal = TimekeepingFirstCutoverTask.journal
      generation = Timekeeping::FirstCutover.new(logger: TimekeepingFirstCutoverTask.logger).abort!
      journal.clear
      puts "Timekeeping first cutover: aborted at generation #{generation}, admission reopened on both copies"
    rescue Timekeeping::FirstCutover::Unresumable, Timekeeping::InternalApi::NotConfigured => error
      abort error.message
    end
  end
end

module TimekeepingRollbackTask
  def self.journal = Timekeeping::RollbackJournal.new(path: ENV.fetch("JOURNAL", Timekeeping::RollbackJournal::DEFAULT_PATH))

  def self.resume_hint(journal)
    "Both copies stay where the run left them, and #{journal.path} keeps what it took. " \
      "Run bin/rails timekeeping:rollback again to resume, or bin/rails timekeeping:rollback:abort to reopen admission."
  end

  def self.reconciled(counts)
    return "reconciled earlier" unless counts

    "reconciled: #{counts.to_h.map { |part, count| "#{count} #{part.to_s.tr('_', ' ')}" }.join(', ')}"
  end
end

namespace :timekeeping do
  desc "Run or resume the rollback from Timekeeping to the prepared application (JOURNAL=path)"
  task rollback: :environment do
    journal = TimekeepingRollbackTask.journal
    result = Timekeeping::Rollback.new(journal:, logger: TimekeepingFirstCutoverTask.logger).call
    journal.clear
    puts "Timekeeping rollback: done at generation #{result.generation}, the prepared application owns entries " \
      "(#{TimekeepingRollbackTask.reconciled(result.reconciled)})"
  rescue Timekeeping::Rollback::Aborted => error
    journal.clear
    abort [error.message, *error.lists.map { |list, ids| "  #{list}: #{Array(ids).join(', ')}" }].join("\n")
  rescue Timekeeping::Rollback::Unresumable, Timekeeping::HandoffJournal::Unreadable, Timekeeping::InternalApi::NotConfigured => error
    abort error.message
  rescue StandardError => error
    raise unless journal

    abort "Timekeeping rollback stopped: #{error.class}: #{error.message}\n#{TimekeepingRollbackTask.resume_hint(journal)}"
  end

  namespace :rollback do
    desc "Abort the rollback in progress, reopening admission on both copies under Timekeeping (JOURNAL=path)"
    task abort: :environment do
      journal = TimekeepingRollbackTask.journal
      generation = Timekeeping::Rollback.new(logger: TimekeepingFirstCutoverTask.logger).abort!
      journal.clear
      puts "Timekeeping rollback: aborted at generation #{generation}, admission reopened on both copies under Timekeeping"
    rescue Timekeeping::Rollback::Unresumable, Timekeeping::InternalApi::NotConfigured => error
      abort error.message
    end
  end
end

module TimekeepingRecutoverTask
  def self.journal = Timekeeping::RecutoverJournal.new(path: ENV.fetch("JOURNAL", Timekeeping::RecutoverJournal::DEFAULT_PATH))

  def self.resume_hint(journal)
    "Both copies stay where the run left them, and #{journal.path} keeps what it took. " \
      "Run bin/rails timekeeping:recutover again to resume, or bin/rails timekeeping:recutover:abort to reopen admission."
  end
end

namespace :timekeeping do
  desc "Run or resume the re-cutover from the prepared application to Timekeeping (JOURNAL=path)"
  task recutover: :environment do
    journal = TimekeepingRecutoverTask.journal
    result = Timekeeping::Recutover.new(journal:, logger: TimekeepingFirstCutoverTask.logger).call
    journal.clear
    puts "Timekeeping re-cutover: done at generation #{result.generation}, Timekeeping owns entries " \
      "(#{TimekeepingRollbackTask.reconciled(result.reconciled)})"
  rescue Timekeeping::Recutover::Aborted => error
    journal.clear
    abort [error.message, *error.lists.map { |list, ids| "  #{list}: #{Array(ids).join(', ')}" }].join("\n")
  rescue Timekeeping::Recutover::Unresumable, Timekeeping::HandoffJournal::Unreadable, Timekeeping::InternalApi::NotConfigured => error
    abort error.message
  rescue StandardError => error
    raise unless journal

    abort "Timekeeping re-cutover stopped: #{error.class}: #{error.message}\n#{TimekeepingRecutoverTask.resume_hint(journal)}"
  end

  namespace :recutover do
    desc "Abort the re-cutover in progress, reopening admission on both copies under the prepared application (JOURNAL=path)"
    task abort: :environment do
      journal = TimekeepingRecutoverTask.journal
      generation = Timekeeping::Recutover.new(logger: TimekeepingFirstCutoverTask.logger).abort!
      journal.clear
      puts "Timekeeping re-cutover: aborted at generation #{generation}, admission reopened on both copies under the prepared application"
    rescue Timekeeping::Recutover::Unresumable, Timekeeping::InternalApi::NotConfigured => error
      abort error.message
    end
  end
end
