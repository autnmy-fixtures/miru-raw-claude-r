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
