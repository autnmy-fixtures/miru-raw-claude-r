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
#
# The end-to-end journey of §13 item 1 (Timekeeping::Journey), on both
# seeded businesses, from a freshly seeded demo: entries, a direct and a
# grouped draft, reservations, reports and PDF, then each handoff above in
# turn, run by its own task, with new writes under every owner:
#
#   bin/rails timekeeping:journey              exit 1 at the first check that fails
#
# It signs in over the existing application's public API at MIRU_URL
# (http://127.0.0.1:3000 by default) as the seeded users, with
# MIRU_SEED_PASSWORD, and the handoffs read what their tasks read.
# JOURNEY_PDF=skip leaves out the PDF downloads, for a runtime with no
# browser for the PDF renderer; JOURNEY_WAIT the seconds a check waits on a
# worker (60 by default).
#
# The alternating-writers proof of §12.4 (Timekeeping::AlternatingWriters),
# on both seeded businesses, from a freshly seeded demo: every writer of §1.3
# writes under each owner in turn, each one an entry another writer wrote
# under the owner before, with each handoff above run by its own task between
# stages:
#
#   bin/rails timekeeping:alternating_writers  exit 1 at the first check that fails
#
# It signs in as the journey does (MIRU_URL, MIRU_SEED_PASSWORD), and
# CHECK_WAIT sets the seconds a check waits on a worker (60 by default).
#
# The live contract check of the independent-deployment proof (§13 item 4,
# Timekeeping::ContractCheck), while Timekeeping owns the entries: on both
# seeded businesses it drives the handoff API, the entry API, the reservation
# API and the entry snapshot between the two running applications:
#
#   bin/rails timekeeping:contract_check       exit 1 at the first check that fails
#
# It signs in as the journey does (MIRU_URL, MIRU_SEED_PASSWORD), reaches
# Timekeeping's handoff API as the handoff tasks do (TIMEKEEPING_URL,
# TIMEKEEPING_TOKEN_KEY), and CHECK_WAIT sets the seconds a check waits on a
# worker (60 by default). bin/timekeeping-demo independent-deploys runs it
# before the two deploys and after each one.
#
# The relay-paused proof (§13 item 5, Timekeeping::RelayPausedCheck), while
# Timekeeping owns the entries, in two halves around a stopped
# timekeeping-relay; RUN names the writes of one run, the same for both:
#
#   bin/rails timekeeping:relay_paused:paused   with the relay stopped: a new
#                                               entry is listed and invoiced
#                                               at once, and is not projected
#   bin/rails timekeeping:relay_paused:resumed  with the relay started again:
#                                               the projection catches up
#
# Each exits 1 at the first check that fails. They sign in as the journey
# does (MIRU_URL, MIRU_SEED_PASSWORD), and CHECK_WAIT sets the seconds a check
# waits on a worker (60 by default). bin/timekeeping-demo relay-paused stops
# and starts the relay around them.
#
# The user-hard-delete proof (§12.4, Timekeeping::UserDeleteRefusedCheck),
# while Timekeeping or the prepared application owns the entries, in two
# halves around the owner's stopped relay; RUN names the writes of one run,
# the same for all three:
#
#   bin/rails timekeeping:user_delete_refused:relay    print the service that
#                                                      runs the owner's relay
#                                                      (timekeeping-relay or
#                                                      miru-jobs)
#   bin/rails timekeeping:user_delete_refused:paused   with that relay stopped:
#                                                      the super-admin delete
#                                                      of a user whose first
#                                                      entry is not projected
#                                                      is refused, with
#                                                      nothing changed
#   bin/rails timekeeping:user_delete_refused:resumed  with it started again:
#                                                      the entry is projected
#
# Each exits 1 at the first check that fails. They sign in as the journey
# does (MIRU_URL, MIRU_SEED_PASSWORD), and CHECK_WAIT sets the seconds a check
# waits on a worker (60 by default). bin/timekeeping-demo user-delete-refused
# stops and starts the relay around them.
#
# The aggregate-line proof (§12.4, F3, Timekeeping::AggregateLineCheck),
# while Timekeeping owns the entries, in three steps around a stopped
# timekeeping-web; RUN names the writes of one run, the same for all three:
#
#   bin/rails timekeeping:aggregate_line:held      a draft's grouped line
#                                                  removed keeps the entry
#                                                  its direct line references
#                                                  and releases the other; a
#                                                  refused save changes
#                                                  nothing
#   bin/rails timekeeping:aggregate_line:outage    with Timekeeping stopped:
#                                                  a save and a destroy of the
#                                                  draft fail, leaving its
#                                                  lines
#   bin/rails timekeeping:aggregate_line:restored  with it started again: the
#                                                  reservations held, and the
#                                                  destroy releases them all
#
# Each exits 1 at the first check that fails. They sign in as the journey
# does (MIRU_URL, MIRU_SEED_PASSWORD), and CHECK_WAIT sets the seconds a check
# waits on a worker (60 by default). bin/timekeeping-demo aggregate-line
# stops and starts timekeeping-web around the outage step.
#
# The billing-writes-during-a-handoff proof (§12.4, §10.1,
# Timekeeping::BillingHandoffCheck), under any owner with admission open, in
# four steps around the handoff that owner hands over with; RUN names the
# writes of one run, the same for all four:
#
#   bin/rails timekeeping:billing_handoff:handoff  print the handoff task to
#                                                  run (first_cutover,
#                                                  rollback or recutover)
#   bin/rails timekeeping:billing_handoff:paused   a billing write paused
#                                                  inside its transaction,
#                                                  until the handoff's step 1
#                                                  waits on it and the run's
#                                                  release marker is written
#   bin/rails timekeeping:billing_handoff:refused  with the handoff stopped
#                                                  after its step 1: invoice,
#                                                  line-item, invoice-tax and
#                                                  payment writes are refused
#                                                  with 503 ownership-moving
#   bin/rails timekeeping:billing_handoff:resumed  once the handoff finished:
#                                                  a payment is accepted again
#
# Each exits 1 at the first check that fails. They sign in as the journey
# does (MIRU_URL, MIRU_SEED_PASSWORD), and CHECK_WAIT sets the seconds a step
# waits on another process (60 by default). bin/timekeeping-demo
# billing-handoff starts the handoff, stops and starts timekeeping-web, and
# writes the release around them.
#
# The save-failure part of the failure injection (§12.4, §9.3,
# Timekeeping::SaveFailuresCheck), while Timekeeping owns the entries, in one
# step; RUN names its writes:
#
#   bin/rails timekeeping:save_failures        a lost prepare answer, a crash
#                                              after prepare, a rolled-back
#                                              save, and the replays of a
#                                              committed, an aborted and a
#                                              forced-pending operation
#
# It exits 1 at the first check that fails. It signs in as the journey does
# (MIRU_URL, MIRU_SEED_PASSWORD), reaches Timekeeping as the invoice writes do
# (TIMEKEEPING_URL, TIMEKEEPING_TOKEN_KEY), and CHECK_WAIT sets the seconds a
# check waits on a worker (60 by default; the crash's recovery waits for the
# save's 30 s time limit too). The crash forks a child process of this one,
# which kills itself. bin/timekeeping-demo save-failures runs it.
#
# The reservation-protocol part of the failure injection (§12.4, §9.3,
# Timekeeping::ReservationFailuresCheck), while Timekeeping owns the entries,
# in two steps around a stopped invoice operation worker (miru-jobs); RUN
# names their writes:
#
#   bin/rails timekeeping:reservation_failures:paused   with miru-jobs
#                                                       stopped: a
#                                                       wrong-company save
#                                                       refused, two saves
#                                                       refused behind an
#                                                       unresolved operation,
#                                                       and every commit and
#                                                       abort answer lost
#   bin/rails timekeeping:reservation_failures:resumed  with it started
#                                                       again: every outcome
#                                                       delivered, the commit
#                                                       sent again changes
#                                                       nothing, and the
#                                                       client's retry goes
#                                                       through
#
# Each exits 1 at the first check that fails. They sign in and reach
# Timekeeping as the save-failures step does, and CHECK_WAIT sets the seconds
# a check waits on a worker (60 by default). The paused step leaves the run's
# state under tmp/timekeeping/reservation-failures for the resumed one.
# bin/timekeeping-demo reservation-failures stops and starts miru-jobs around
# them.
#
# The hard-delete-of-a-non-draft part of the failure injection (§12.4, §9.3,
# §7.3, Timekeeping::HardDeleteCheck), while Timekeeping or the prepared
# application owns the entries, in one step; RUN names its writes:
#
#   bin/rails timekeeping:hard_delete          a bulk delete of a sent invoice
#                                              with a recorded payment fails
#                                              and changes nothing; one of a
#                                              sent invoice with none keeps its
#                                              entry's edit lock, retained,
#                                              until a successor draft takes
#                                              it over
#
# It exits 1 at the first check that fails. It signs in and reaches the owner
# as the save-failures step does, and CHECK_WAIT sets the seconds a check
# waits on a worker (60 by default). bin/timekeeping-demo hard-delete runs it.
#
# The stale-generation part of the failure injection (§12.4, §9.3,
# Timekeeping::StaleGenerationCheck), while Timekeeping owns the entries, in
# one step; RUN names its writes:
#
#   bin/rails timekeeping:stale_generation     entry writes and reservation
#                                              calls carrying another
#                                              generation are refused 409
#                                              stale-generation and change
#                                              nothing; the gateway's retry of
#                                              one never admitted goes
#                                              through, and an admitted one's
#                                              retry answers its stored result
#
# It exits 1 at the first check that fails. It signs in and reaches
# Timekeeping as the save-failures step does, and CHECK_WAIT sets the seconds
# a check waits on a worker (60 by default). Its last line names the request
# id of every refused call. bin/timekeeping-demo stale-generation runs it,
# and then finds Timekeeping's alert for each id in timekeeping-web's log.
#
# The projection-consumer-down part of the failure injection (§12.4, §9.3,
# Timekeeping::ConsumerDownCheck), while Timekeeping owns the entries, in
# three steps around a consumer that timekeeping-relay cannot reach; RUN
# names the writes of one run, the same for all three:
#
#   bin/rails timekeeping:consumer_down:projected  with the consumer up: a
#                                                  new entry X is projected
#   bin/rails timekeeping:consumer_down:down       with it down: X edited and
#                                                  a new entry Y are listed
#                                                  and invoiced at once, and
#                                                  the projection stays as
#                                                  it was
#   bin/rails timekeeping:consumer_down:restored   with it back: the
#                                                  projection holds X and Y
#                                                  at Timekeeping's versions
#
# Each exits 1 at the first check that fails. They sign in and reach
# Timekeeping as the save-failures step does, and CHECK_WAIT sets the seconds
# a check waits on a worker (60 by default). bin/timekeeping-demo
# consumer-down takes the consumer down and brings it back around them.
#
# The duplicate-and-reordered-delivery part of §13 item 6
# (Timekeeping::RedeliveryCheck), while Timekeeping owns the entries, in four
# steps around a stopped relay and Timekeeping's own out-of-order resend
# (bin/rails timekeeping:redeliver there); RUN names the writes of one run,
# the same for all four:
#
#   bin/rails timekeeping:redelivery:projected   relay running: a new entry
#                                                X is projected
#   bin/rails timekeeping:redelivery:held        relay stopped: X edited, Y
#                                                written, both reserved, and
#                                                the projection behind; the
#                                                last line names the entries
#   bin/rails timekeeping:redelivery:reordered   relay still stopped, after
#                                                the resend: the projection
#                                                holds both as Timekeeping does
#   bin/rails timekeeping:redelivery:duplicated  after the relay sent them all
#                                                again: still exactly so
#
# Each exits 1 at the first check that fails. They sign in and reach
# Timekeeping as the save-failures step does, and CHECK_WAIT sets the seconds
# a check waits on a worker (60 by default). bin/timekeeping-demo redelivery
# stops and starts the relay and runs the resend around them.
#
# What the existing application measures of its Timekeeping machinery
# (§11.3, Timekeeping::Signals), read once, for an operator or a script:
#
#   bin/rails timekeeping:signals              print each signal; exit 1 on an alert
#
# It reports nothing: the dedicated workers report the alerts
# (Timekeeping::RelaySignalJob, Timekeeping::InvoiceOperationSignalsJob).
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

module TimekeepingSignalsTask
  def self.lines(reading)
    [
      "ownership: #{reading.ownership}",
      "relay lag: #{reading.relay_lag.round(1)} s, #{reading.relay_backlog} position(s) undelivered" \
        "#{' (above the limit for the whole window)' if reading.relay_lag_sustained}",
      "invoice operations pending past the limit: #{reading.pending_operations.size}",
      "commits or aborts undelivered past the limit: #{reading.undelivered_outcomes.size}"
    ]
  end
end

namespace :timekeeping do
  desc "Print the existing application's Timekeeping signals (docs/architecture/timekeeping-soa.md 11.3); exit 1 on an alert"
  task signals: :environment do
    signals = Timekeeping::Signals.new
    puts TimekeepingSignalsTask.lines(signals.read)
    alerts = signals.alerts
    abort alerts.map { |alert| "ALERT #{alert.message}" }.join("\n") if alerts.any?
    puts "no alerts"
  end
end

namespace :timekeeping do
  desc "Run the end-to-end journey of docs/architecture/timekeeping-soa.md 13 item 1 on the seeded demo (MIRU_URL, MIRU_SEED_PASSWORD)"
  task journey: :environment do
    handoff = lambda do |name|
      task = Rake::Task["timekeeping:#{name}"]
      task.reenable
      task.invoke
    end
    Timekeeping::Journey.new(
      client: Timekeeping::Journey::Client.new(base_url: ENV.fetch("MIRU_URL", "http://127.0.0.1:3000")),
      password: ENV.fetch("MIRU_SEED_PASSWORD") { abort "MIRU_SEED_PASSWORD is the seeded users' password; the journey signs in with it" },
      handoff:, logger: TimekeepingFirstCutoverTask.logger,
      options: Timekeeping::Journey::Options.new(
        pdf: ENV["JOURNEY_PDF"] != "skip", wait: Integer(ENV.fetch("JOURNEY_WAIT", Timekeeping::Journey::DEFAULT_WAIT))
      )
    ).call
  rescue Timekeeping::Journey::Failed => error
    abort "Timekeeping journey failed: #{error.message}"
  end
end

namespace :timekeeping do
  desc "Run every writer across cutover, rollback and re-cutover on the seeded demo (docs/architecture/timekeeping-soa.md 12.4; MIRU_URL, MIRU_SEED_PASSWORD)"
  task alternating_writers: :environment do
    handoff = lambda do |name|
      task = Rake::Task["timekeeping:#{name}"]
      task.reenable
      task.invoke
    end
    Timekeeping::AlternatingWriters.new(
      client: Timekeeping::PublicApi::Client.new(base_url: ENV.fetch("MIRU_URL", "http://127.0.0.1:3000")),
      password: ENV.fetch("MIRU_SEED_PASSWORD") { abort "MIRU_SEED_PASSWORD is the seeded users' password; the run signs in with it" },
      handoff:, logger: TimekeepingFirstCutoverTask.logger,
      options: Timekeeping::AlternatingWriters::Options.new(wait: Integer(ENV.fetch("CHECK_WAIT", Timekeeping::PublicApi::DEFAULT_WAIT)))
    ).call
  rescue Timekeeping::AlternatingWriters::Failed => error
    abort "Timekeeping alternating writers failed: #{error.message}"
  end
end

namespace :timekeeping do
  desc "Check every Timekeeping contract between the two running applications (docs/architecture/timekeeping-soa.md 13 item 4)"
  task contract_check: :environment do
    Timekeeping::ContractCheck.new(
      client: Timekeeping::PublicApi::Client.new(base_url: ENV.fetch("MIRU_URL", "http://127.0.0.1:3000")),
      password: ENV.fetch("MIRU_SEED_PASSWORD") { abort "MIRU_SEED_PASSWORD is the seeded users' password; the check signs in with it" },
      logger: TimekeepingFirstCutoverTask.logger,
      options: Timekeeping::ContractCheck::Options.new(wait: Integer(ENV.fetch("CHECK_WAIT", Timekeeping::PublicApi::DEFAULT_WAIT)))
    ).call
  rescue Timekeeping::ContractCheck::Failed, Timekeeping::InternalApi::Error => error
    abort "Timekeeping contract check failed: #{error.class}: #{error.message}"
  end
end

module TimekeepingRelayPausedTask
  def self.check
    Timekeeping::RelayPausedCheck.new(
      client: Timekeeping::PublicApi::Client.new(base_url: ENV.fetch("MIRU_URL", "http://127.0.0.1:3000")),
      password: ENV.fetch("MIRU_SEED_PASSWORD") { abort "MIRU_SEED_PASSWORD is the seeded users' password; the check signs in with it" },
      run: ENV.fetch("RUN") { abort "RUN names the writes of one run; give both halves the same one" },
      logger: TimekeepingFirstCutoverTask.logger,
      options: Timekeeping::RelayPausedCheck::Options.new(wait: Integer(ENV.fetch("CHECK_WAIT", Timekeeping::PublicApi::DEFAULT_WAIT)))
    )
  end

  def self.run(half)
    check.public_send(half)
  rescue Timekeeping::RelayPausedCheck::Failed => error
    abort "Timekeeping relay-paused proof failed (#{half}): #{error.message}"
  end
end

namespace :timekeeping do
  namespace :relay_paused do
    desc "With Timekeeping's relay stopped: a new entry is listed and invoiced at once (docs/architecture/timekeeping-soa.md 13 item 5; RUN)"
    task paused: :environment do
      TimekeepingRelayPausedTask.run(:paused)
    end

    desc "With Timekeeping's relay started again: the projection catches up (docs/architecture/timekeeping-soa.md 13 item 5; RUN)"
    task resumed: :environment do
      TimekeepingRelayPausedTask.run(:resumed)
    end
  end
end

module TimekeepingUserDeleteRefusedTask
  def self.check
    Timekeeping::UserDeleteRefusedCheck.new(
      client: Timekeeping::PublicApi::Client.new(base_url: ENV.fetch("MIRU_URL", "http://127.0.0.1:3000")),
      password: ENV.fetch("MIRU_SEED_PASSWORD") { abort "MIRU_SEED_PASSWORD is the seeded users' password; the check signs in with it" },
      run: ENV.fetch("RUN") { abort "RUN names the writes of one run; give every step the same one" },
      logger: TimekeepingFirstCutoverTask.logger,
      options: Timekeeping::UserDeleteRefusedCheck::Options.new(wait: Integer(ENV.fetch("CHECK_WAIT", Timekeeping::PublicApi::DEFAULT_WAIT)))
    )
  end

  def self.run(step)
    result = check.public_send(step)
    puts result if step == :relay
  rescue Timekeeping::UserDeleteRefusedCheck::Failed => error
    abort "Timekeeping user-delete proof failed (#{step}): #{error.message}"
  end
end

namespace :timekeeping do
  namespace :user_delete_refused do
    desc "Print the service that runs the current owner's relay, for the user-delete proof (docs/architecture/timekeeping-soa.md 12.4; RUN)"
    task relay: :environment do
      TimekeepingUserDeleteRefusedTask.run(:relay)
    end

    desc "With the owner's relay stopped: a user's hard delete is refused, with nothing changed (docs/architecture/timekeeping-soa.md 12.4; RUN)"
    task paused: :environment do
      TimekeepingUserDeleteRefusedTask.run(:paused)
    end

    desc "With the owner's relay started again: the refused user's entry is projected (docs/architecture/timekeeping-soa.md 12.4; RUN)"
    task resumed: :environment do
      TimekeepingUserDeleteRefusedTask.run(:resumed)
    end
  end
end

module TimekeepingAggregateLineTask
  def self.check
    Timekeeping::AggregateLineCheck.new(
      client: Timekeeping::PublicApi::Client.new(base_url: ENV.fetch("MIRU_URL", "http://127.0.0.1:3000")),
      password: ENV.fetch("MIRU_SEED_PASSWORD") { abort "MIRU_SEED_PASSWORD is the seeded users' password; the check signs in with it" },
      run: ENV.fetch("RUN") { abort "RUN names the writes of one run; give every step the same one" },
      logger: TimekeepingFirstCutoverTask.logger,
      options: Timekeeping::AggregateLineCheck::Options.new(wait: Integer(ENV.fetch("CHECK_WAIT", Timekeeping::PublicApi::DEFAULT_WAIT)))
    )
  end

  def self.run(step)
    check.public_send(step)
  rescue Timekeeping::AggregateLineCheck::Failed => error
    abort "Timekeeping aggregate-line proof failed (#{step}): #{error.message}"
  end
end

namespace :timekeeping do
  namespace :aggregate_line do
    desc "A draft's grouped line removed keeps the entry another line references and releases the rest (docs/architecture/timekeeping-soa.md 12.4, F3; RUN)"
    task held: :environment do
      TimekeepingAggregateLineTask.run(:held)
    end

    desc "With Timekeeping stopped: a save and a destroy of the draft fail and keep its reservations (docs/architecture/timekeeping-soa.md 12.4, F3; RUN)"
    task outage: :environment do
      TimekeepingAggregateLineTask.run(:outage)
    end

    desc "With Timekeeping started again: the reservations held, and destroying the draft releases its whole set (docs/architecture/timekeeping-soa.md 12.4, F3; RUN)"
    task restored: :environment do
      TimekeepingAggregateLineTask.run(:restored)
    end
  end
end

module TimekeepingBillingHandoffTask
  def self.check
    Timekeeping::BillingHandoffCheck.new(
      client: Timekeeping::PublicApi::Client.new(base_url: ENV.fetch("MIRU_URL", "http://127.0.0.1:3000")),
      password: ENV.fetch("MIRU_SEED_PASSWORD") { abort "MIRU_SEED_PASSWORD is the seeded users' password; the check signs in with it" },
      run: ENV.fetch("RUN") { abort "RUN names the writes of one run; give every step the same one" },
      logger: TimekeepingFirstCutoverTask.logger,
      options: Timekeeping::BillingHandoffCheck::Options.new(wait: Integer(ENV.fetch("CHECK_WAIT", Timekeeping::PublicApi::DEFAULT_WAIT)))
    )
  end

  def self.run(step)
    result = check.public_send(step)
    puts result if step == :handoff
  rescue Timekeeping::BillingHandoffCheck::Failed => error
    abort "Timekeeping billing-handoff proof failed (#{step}): #{error.message}"
  end
end

namespace :timekeeping do
  namespace :billing_handoff do
    desc "Print the handoff task the current owner hands over with, for the billing-handoff proof (docs/architecture/timekeeping-soa.md 12.4; RUN)"
    task handoff: :environment do
      TimekeepingBillingHandoffTask.run(:handoff)
    end

    desc "A billing write paused inside its transaction until the handoff's step 1 waits on it (docs/architecture/timekeeping-soa.md 12.4; RUN)"
    task paused: :environment do
      TimekeepingBillingHandoffTask.run(:paused)
    end

    desc "With the handoff stopped after its step 1: billing writes are refused with 503 ownership-moving (docs/architecture/timekeeping-soa.md 12.4; RUN)"
    task refused: :environment do
      TimekeepingBillingHandoffTask.run(:refused)
    end

    desc "Once the handoff finished: a payment is accepted again (docs/architecture/timekeeping-soa.md 12.4; RUN)"
    task resumed: :environment do
      TimekeepingBillingHandoffTask.run(:resumed)
    end
  end
end

module TimekeepingSaveFailuresTask
  def self.check
    Timekeeping::SaveFailuresCheck.new(
      client: Timekeeping::PublicApi::Client.new(base_url: ENV.fetch("MIRU_URL", "http://127.0.0.1:3000")),
      password: ENV.fetch("MIRU_SEED_PASSWORD") { abort "MIRU_SEED_PASSWORD is the seeded users' password; the check signs in with it" },
      run: ENV.fetch("RUN") { abort "RUN names the writes of one run" },
      logger: TimekeepingFirstCutoverTask.logger,
      options: Timekeeping::SaveFailuresCheck::Options.new(wait: Integer(ENV.fetch("CHECK_WAIT", Timekeeping::PublicApi::DEFAULT_WAIT)))
    )
  end

  def self.run
    check.call
  rescue Timekeeping::SaveFailuresCheck::Failed => error
    abort "Timekeeping save-failures proof failed: #{error.message}"
  end
end

namespace :timekeeping do
  desc "A lost prepare answer, a crash after prepare, a rolled-back save and terminal-receipt replays each leave what 9.3 says (docs/architecture/timekeeping-soa.md 12.4; RUN)"
  task save_failures: :environment do
    TimekeepingSaveFailuresTask.run
  end
end

module TimekeepingReservationFailuresTask
  def self.check
    Timekeeping::ReservationFailuresCheck.new(
      client: Timekeeping::PublicApi::Client.new(base_url: ENV.fetch("MIRU_URL", "http://127.0.0.1:3000")),
      password: ENV.fetch("MIRU_SEED_PASSWORD") { abort "MIRU_SEED_PASSWORD is the seeded users' password; the check signs in with it" },
      run: ENV.fetch("RUN") { abort "RUN names the writes of one run; give both steps the same one" },
      logger: TimekeepingFirstCutoverTask.logger,
      options: Timekeeping::ReservationFailuresCheck::Options.new(wait: Integer(ENV.fetch("CHECK_WAIT", Timekeeping::PublicApi::DEFAULT_WAIT)))
    )
  end

  def self.run(step)
    check.public_send(step)
  rescue Timekeeping::ReservationFailuresCheck::Failed => error
    abort "Timekeeping reservation-failures proof failed (#{step}): #{error.message}"
  end
end

namespace :timekeeping do
  namespace :reservation_failures do
    desc "With the invoice operation worker stopped: a wrong-company save and two saves behind an unresolved operation refused, commit answers lost (docs/architecture/timekeeping-soa.md 12.4; RUN)"
    task paused: :environment do
      TimekeepingReservationFailuresTask.run(:paused)
    end

    desc "With the invoice operation worker started again: every outcome delivered, the resent commit changes nothing, the retry goes through (docs/architecture/timekeeping-soa.md 12.4; RUN)"
    task resumed: :environment do
      TimekeepingReservationFailuresTask.run(:resumed)
    end
  end
end

module TimekeepingHardDeleteTask
  def self.check
    Timekeeping::HardDeleteCheck.new(
      client: Timekeeping::PublicApi::Client.new(base_url: ENV.fetch("MIRU_URL", "http://127.0.0.1:3000")),
      password: ENV.fetch("MIRU_SEED_PASSWORD") { abort "MIRU_SEED_PASSWORD is the seeded users' password; the check signs in with it" },
      run: ENV.fetch("RUN") { abort "RUN names the writes of one run" },
      logger: TimekeepingFirstCutoverTask.logger,
      options: Timekeeping::HardDeleteCheck::Options.new(wait: Integer(ENV.fetch("CHECK_WAIT", Timekeeping::PublicApi::DEFAULT_WAIT)))
    )
  end

  def self.run
    check.call
  rescue Timekeeping::HardDeleteCheck::Failed => error
    abort "Timekeeping hard-delete proof failed: #{error.message}"
  end
end

namespace :timekeeping do
  desc "A failed hard delete of a non-draft changes nothing; a successful one keeps the edit lock until a successor (docs/architecture/timekeeping-soa.md 12.4, 9.3; RUN)"
  task hard_delete: :environment do
    TimekeepingHardDeleteTask.run
  end
end

module TimekeepingStaleGenerationTask
  def self.check
    Timekeeping::StaleGenerationCheck.new(
      client: Timekeeping::PublicApi::Client.new(base_url: ENV.fetch("MIRU_URL", "http://127.0.0.1:3000")),
      password: ENV.fetch("MIRU_SEED_PASSWORD") { abort "MIRU_SEED_PASSWORD is the seeded users' password; the check signs in with it" },
      run: ENV.fetch("RUN") { abort "RUN names the writes of one run" },
      logger: TimekeepingFirstCutoverTask.logger,
      options: Timekeeping::StaleGenerationCheck::Options.new(wait: Integer(ENV.fetch("CHECK_WAIT", Timekeeping::PublicApi::DEFAULT_WAIT)))
    )
  end

  def self.run
    check.call
  rescue Timekeeping::StaleGenerationCheck::Failed => error
    abort "Timekeeping stale-generation proof failed: #{error.message}"
  end
end

namespace :timekeeping do
  desc "Calls carrying another generation are refused 409 stale-generation and change nothing; retries go to the current owner (docs/architecture/timekeeping-soa.md 12.4, 9.3; RUN)"
  task stale_generation: :environment do
    TimekeepingStaleGenerationTask.run
  end
end

module TimekeepingConsumerDownTask
  def self.check
    Timekeeping::ConsumerDownCheck.new(
      client: Timekeeping::PublicApi::Client.new(base_url: ENV.fetch("MIRU_URL", "http://127.0.0.1:3000")),
      password: ENV.fetch("MIRU_SEED_PASSWORD") { abort "MIRU_SEED_PASSWORD is the seeded users' password; the check signs in with it" },
      run: ENV.fetch("RUN") { abort "RUN names the writes of one run; give all three steps the same one" },
      logger: TimekeepingFirstCutoverTask.logger,
      options: Timekeeping::ConsumerDownCheck::Options.new(wait: Integer(ENV.fetch("CHECK_WAIT", Timekeeping::PublicApi::DEFAULT_WAIT)))
    )
  end

  def self.run(step)
    check.public_send(step)
  rescue Timekeeping::ConsumerDownCheck::Failed, Timekeeping::InternalApi::Error => error
    abort "Timekeeping consumer-down proof failed (#{step}): #{error.message}"
  end
end

namespace :timekeeping do
  namespace :consumer_down do
    desc "With the projection consumer up: a new entry is projected (docs/architecture/timekeeping-soa.md 12.4, 9.3; RUN)"
    task projected: :environment do
      TimekeepingConsumerDownTask.run(:projected)
    end

    desc "With the projection consumer down: entries are listed and invoiced at once, the projection stays as it was (docs/architecture/timekeeping-soa.md 12.4, 9.3; RUN)"
    task down: :environment do
      TimekeepingConsumerDownTask.run(:down)
    end

    desc "With the projection consumer back: the relay's resend brings the projection to Timekeeping's versions (docs/architecture/timekeeping-soa.md 12.4, 9.3; RUN)"
    task restored: :environment do
      TimekeepingConsumerDownTask.run(:restored)
    end
  end
end

module TimekeepingRedeliveryTask
  def self.check
    Timekeeping::RedeliveryCheck.new(
      client: Timekeeping::PublicApi::Client.new(base_url: ENV.fetch("MIRU_URL", "http://127.0.0.1:3000")),
      password: ENV.fetch("MIRU_SEED_PASSWORD") { abort "MIRU_SEED_PASSWORD is the seeded users' password; the check signs in with it" },
      run: ENV.fetch("RUN") { abort "RUN names the writes of one run; give all four steps the same one" },
      logger: TimekeepingFirstCutoverTask.logger,
      options: Timekeeping::RedeliveryCheck::Options.new(wait: Integer(ENV.fetch("CHECK_WAIT", Timekeeping::PublicApi::DEFAULT_WAIT)))
    )
  end

  def self.run(step)
    check.public_send(step)
  rescue Timekeeping::RedeliveryCheck::Failed, Timekeeping::InternalApi::Error => error
    abort "Timekeeping redelivery proof failed (#{step}): #{error.message}"
  end
end

namespace :timekeeping do
  namespace :redelivery do
    desc "With the relay running: a new entry is projected (docs/architecture/timekeeping-soa.md 13 item 6; RUN)"
    task projected: :environment do
      TimekeepingRedeliveryTask.run(:projected)
    end

    desc "With the relay stopped: entries edited and reserved, the projection behind; names the entries (docs/architecture/timekeeping-soa.md 13 item 6; RUN)"
    task held: :environment do
      TimekeepingRedeliveryTask.run(:held)
    end

    desc "After Timekeeping's out-of-order resend: the projection holds Timekeeping's versions (docs/architecture/timekeeping-soa.md 13 item 6; RUN)"
    task reordered: :environment do
      TimekeepingRedeliveryTask.run(:reordered)
    end

    desc "After the relay delivered every snapshot again: nothing changed (docs/architecture/timekeeping-soa.md 13 item 6; RUN)"
    task duplicated: :environment do
      TimekeepingRedeliveryTask.run(:duplicated)
    end
  end
end
