# frozen_string_literal: true

# What Timekeeping measures of itself (docs/architecture/timekeeping-soa.md
# §11.3, Signals), read once, for an operator or a script, from any process
# of the image, so a relay worker that has stopped can still be read:
#
#   bin/rails timekeeping:signals              print each signal; exit 1 on an alert
#
# It reports nothing: the relay's worker reports the alert (SignalsJob).
module TimekeepingSignalsTask
  def self.lines(reading)
    [
      "ownership: #{reading.ownership}",
      "relay lag: #{reading.relay_lag.round(1)} s, #{reading.relay_backlog} position(s) undelivered" \
        "#{' (above the limit for the whole window)' if reading.relay_lag_sustained}"
    ]
  end
end

namespace :timekeeping do
  desc "Print Timekeeping's own signals (docs/architecture/timekeeping-soa.md 11.3); exit 1 on an alert"
  task signals: :environment do
    signals = Signals.new
    puts TimekeepingSignalsTask.lines(signals.read)
    alerts = signals.alerts
    abort alerts.map { |alert| "ALERT #{alert.message}" }.join("\n") if alerts.any?
    puts "no alerts"
  end
end
