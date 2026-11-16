# frozen_string_literal: true

require "rails_helper"
require "open3"
require "uri"
require "yaml"

# The Timekeeping local demo runtime (docs/architecture/timekeeping-soa.md
# §11.1, §11.2, §14 "Deployment and runtime"): docker-compose.timekeeping-demo.yml,
# config/solid_queue_timekeeping_demo.yml and bin/timekeeping-demo. These read
# the files as written; nothing here starts a container.
RSpec.describe "Timekeeping local demo runtime" do
  let(:compose) { YAML.safe_load(Rails.root.join("docker-compose.timekeeping-demo.yml").read, aliases: true) }
  let(:services) { compose.fetch("services") }
  let(:existing_services) { services.slice("miru-web", "miru-jobs") }
  let(:timekeeping_services) { services.slice("timekeeping-web", "timekeeping-relay") }

  # The variables a compose value interpolates, `${NAME…}`.
  def variables(value)
    value.to_s.scan(/\$\{([A-Z0-9_]+)/).flatten
  end

  # A compose DATABASE_URL with its interpolations replaced, so URI parses it.
  def database_url(service)
    URI.parse(services.dig(service, "environment", "DATABASE_URL").gsub(/\$\{[^}]+\}/, "secret"))
  end

  describe "images" do
    it "runs each application from its own image, built from its own Dockerfile" do
      expect(services.dig("miru-web", "build")).to include("context" => ".", "dockerfile" => "Dockerfile", "target" => "development")
      expect(services.dig("timekeeping-web", "build")).to include("context" => ".", "dockerfile" => "services/timekeeping/Dockerfile")
      expect(services.dig("miru-web", "image")).not_to eq(services.dig("timekeeping-web", "image"))
    end

    it "runs each worker from its own application's image, never pulled or built on its own" do
      expect(services["miru-jobs"]).to include("image" => services.dig("miru-web", "image"), "pull_policy" => "never")
      expect(services["timekeeping-relay"]).to include("image" => services.dig("timekeeping-web", "image"), "pull_policy" => "never")
      expect(services["miru-jobs"]).not_to have_key("build")
      expect(services["timekeeping-relay"]).not_to have_key("build")
    end

    it "records the revision each image is built from" do
      expect(variables(services.dig("miru-web", "build", "labels", "org.opencontainers.image.revision"))).to eq(["MIRU_REVISION"])
      expect(variables(services.dig("timekeeping-web", "build", "args", "REVISION"))).to eq(["TIMEKEEPING_REVISION"])
      expect(Rails.root.join("services/timekeeping/Dockerfile").read).to include('org.opencontainers.image.revision="${REVISION}"')
    end
  end

  describe "databases and credentials" do
    it "gives each application its own Postgres server and database" do
      expect(existing_services.keys.map { |name| database_url(name).host }.uniq).to eq(["miru-db"])
      expect(timekeeping_services.keys.map { |name| database_url(name).host }.uniq).to eq(["timekeeping-db"])
      expect(database_url("miru-web").path).to eq("/miru_web_development")
      expect(database_url("timekeeping-web").path).to eq("/timekeeping_production")
      expect(services.dig("miru-db", "volumes")).not_to eq(services.dig("timekeeping-db", "volumes"))
    end

    it "shares no database credential: each server's user and password are its application's own" do
      expect(services.dig("miru-db", "environment")).to include("POSTGRES_USER" => "miru")
      expect(services.dig("timekeeping-db", "environment")).to include("POSTGRES_USER" => "timekeeping")
      expect(variables(services.dig("miru-db", "environment", "POSTGRES_PASSWORD"))).to eq(["MIRU_DB_PASSWORD"])
      expect(variables(services.dig("timekeeping-db", "environment", "POSTGRES_PASSWORD"))).to eq(["TIMEKEEPING_DB_PASSWORD"])
      expect(database_url("miru-web").user).to eq("miru")
      expect(database_url("timekeeping-web").user).to eq("timekeeping")
    end

    it "shares only the token key between the two applications" do
      read = ->(group) { group.values.flat_map { |service| service.fetch("environment").values.flat_map { |value| variables(value) } }.uniq }

      expect(read.call(existing_services) & read.call(timekeeping_services)).to eq(["TIMEKEEPING_TOKEN_KEY"])
      expect(read.call(existing_services)).not_to include("TIMEKEEPING_DB_PASSWORD", "TIMEKEEPING_SECRET_KEY_BASE")
      expect(read.call(timekeeping_services)).not_to include("MIRU_DB_PASSWORD", "MIRU_SECRET_KEY_BASE")
    end

    it "keeps every credential out of the file: each is a required variable, never a value" do
      credentials = services.values.flat_map do |service|
        service.fetch("environment", {}).select { |key, _| key.match?(/PASSWORD|SECRET|TOKEN_KEY|DATABASE_URL/) }.values
      end

      # The two servers' passwords, and the four application processes' own.
      expect(credentials.size).to eq(2 + (2 * 4) + (2 * 3))
      credentials.each do |value|
        expect(value).to match(/\$\{[A-Z0-9_]+:\?/)
        expect(value.gsub(/\$\{[^}]+\}/, "")).not_to match(/:[^\/@]+@/) # no literal password in a URL
      end
      expect(credentials.filter_map { |value| value[/\A\$\{[^}]+\}\z/] }).to all(match(/:\?run bin\/timekeeping-demo init\}\z/))
    end
  end

  describe "the dedicated workers" do
    let(:demo_queue_config) { SolidQueue::Configuration.new(load_from: Rails.root.join(services.dig("miru-jobs", "environment", "SOLID_QUEUE_CONFIG"))) }
    let(:processes) { demo_queue_config.configured_processes }
    let(:local_config) { YAML.safe_load(ERB.new(Rails.root.join("config/solid_queue.yml").read).result, aliases: true).fetch("default") }

    it "starts no worker in the web processes" do
      expect(services.dig("miru-web", "command")).to eq(["bundle", "exec", "falcon", "serve", "--bind", "http://0.0.0.0:3000"])
      expect(services.dig("timekeeping-web")).not_to have_key("command")
      expect(services.values.filter_map { |service| service["command"]&.join(" ") }.grep(/solid_queue/))
        .to contain_exactly("bundle exec rake solid_queue:start", "bin/rails solid_queue:start")
    end

    it "starts the existing application's invoice operation worker and its local relay, and no default worker" do
      expect(services.dig("miru-jobs", "environment", "SOLID_QUEUE_CONFIG")).to eq("config/solid_queue_timekeeping_demo.yml")

      workers = processes.select { |process| process.kind == :worker }
      expect(workers.map { |worker| worker.attributes[:queues] }).to eq(["invoice_operations", "timekeeping_relay"])
      expect(workers.map { |worker| worker.attributes[:processes] }).to eq([1, 1])
    end

    it "schedules only the Timekeeping jobs, each onto a queue a dedicated worker reads" do
      dispatchers = processes.select { |process| process.kind == :dispatcher }
      tasks = dispatchers.sole.attributes[:recurring_tasks]
      queues = processes.filter_map { |process| process.attributes[:queues] if process.kind == :worker }

      expect(tasks.map(&:class_name)).to contain_exactly(
        "Timekeeping::InvoiceOperationsJob", "Timekeeping::LocalRelayJob",
        "Timekeeping::RelaySignalJob", "Timekeeping::InvoiceOperationSignalsJob"
      )
      expect(tasks.map { |task| task.class_name.constantize.new.queue_name }).to all(be_in(queues))
    end

    it "keeps the same schedules and worker settings as the local runtime's config/solid_queue.yml" do
      demo = YAML.safe_load(Rails.root.join("config/solid_queue_timekeeping_demo.yml").read)

      expect(demo.dig("dispatchers", 0, "recurring_tasks"))
        .to eq(local_config.dig("dispatchers", 0, "recurring_tasks").slice(
          "invoice_operations", "timekeeping_local_relay", "timekeeping_relay_signal", "timekeeping_invoice_operation_signals"
        ))
      expect(demo.fetch("workers"))
        .to eq(local_config.fetch("workers").select { |worker| %w[invoice_operations timekeeping_relay].include?(worker["queues"]) })
    end

    it "starts Timekeeping's relay worker, which reads timekeeping_relay only" do
      timekeeping_queues = YAML.safe_load(Rails.root.join("services/timekeeping/config/solid_queue.yml").read, aliases: true)

      expect(services.dig("timekeeping-relay", "command")).to eq(["bin/rails", "solid_queue:start"])
      expect(timekeeping_queues.dig("production", "workers").pluck("queues")).to eq(["timekeeping_relay"])
    end

    it "starts each worker once its web process is healthy, so only the web process migrates" do
      expect(services.dig("miru-jobs", "depends_on")).to eq("miru-web" => { "condition" => "service_healthy" })
      expect(services.dig("timekeeping-relay", "depends_on")).to eq("timekeeping-web" => { "condition" => "service_healthy" })
      expect(Rails.root.join("bin/docker-entrypoint").read).to include('*"falcon serve"*')
    end
  end

  describe "wiring" do
    it "points each application at the other by service name, on the port it serves" do
      expect(services.dig("miru-web", "environment", "TIMEKEEPING_URL")).to eq("http://timekeeping-web:3100")
      expect(services.dig("timekeeping-web", "environment", "EXISTING_APP_URL")).to eq("http://miru-web:3000")
      expect(services.dig("miru-web", "environment", "RAILS_DEVELOPMENT_HOSTS").split(",")).to include("miru-web")
      expect(Rails.root.join("services/timekeeping/Dockerfile").read).to include("ENV PORT=3100")
    end

    it "lets the existing application seed in a container: a seed password of its own, and mail that opens no browser" do
      environment = services.dig("miru-web", "environment")

      expect(variables(environment.fetch("MIRU_SEED_PASSWORD"))).to eq(["MIRU_SEED_PASSWORD"])
      expect(Rails.root.join("db/seeds.rb").read).to include('ENV.fetch("MIRU_SEED_PASSWORD"')
      expect(environment.fetch("BROWSER")).to eq("/bin/true")
      expect(Rails.application.config.action_mailer.delivery_method).to eq(:test) # letter_opener is development's
    end

    it "publishes the two web processes on loopback only, and no database" do
      expect(services.dig("miru-web", "ports")).to eq(["127.0.0.1:3000:3000"])
      expect(services.dig("timekeeping-web", "ports")).to eq(["127.0.0.1:3100:3100"])
      expect(services.except("miru-web", "timekeeping-web").values.filter_map { |service| service["ports"] }).to be_empty
    end

    it "gives the handoff runners their journals and the recorded seed disposition at the paths they read by default" do
      workdir = Rails.root.join("Dockerfile").read[/^WORKDIR (\S+)/, 1]
      journal_dirs = [Timekeeping::FirstCutoverJournal, Timekeeping::RollbackJournal, Timekeeping::RecutoverJournal]
        .map { |journal| File.dirname(journal::DEFAULT_PATH) }.uniq

      expect(services.dig("miru-web", "volumes")).to include(
        "miru_handoff_journals:#{workdir}/#{journal_dirs.sole}",
        "./#{Timekeeping::RecordedDisposition::SEED}:#{workdir}/#{Timekeeping::RecordedDisposition::SEED}:ro"
      )
      expect(services.dig("miru-jobs", "volumes")).to eq(services.dig("miru-web", "volumes"))
      expect(Rails.root.join(Timekeeping::RecordedDisposition::SEED)).to exist
    end
  end

  describe "bin/timekeeping-demo" do
    let(:dir) { Pathname(Dir.mktmpdir("timekeeping-demo")) }
    let(:env_file) { dir.join("demo.env") }
    let(:docker_log) { dir.join("docker.log") }
    let(:script) { Rails.root.join("bin/timekeeping-demo").to_s }

    before do
      # A stand-in for docker that records how it was called and starts nothing.
      dir.join("bin").mkpath
      dir.join("bin/docker").write("#!/bin/sh\necho \"$*\" >> \"#{docker_log}\"\n")
      dir.join("bin/docker").chmod(0o755)
    end

    after { FileUtils.remove_entry(dir) }

    def run(*args)
      Open3.capture3(
        { "TIMEKEEPING_DEMO_ENV_FILE" => env_file.to_s, "PATH" => "#{dir.join('bin')}:#{ENV.fetch('PATH')}" },
        script, *args
      )
    end

    def docker_calls
      docker_log.exist? ? docker_log.readlines(chomp: true) : []
    end

    def prefix = "compose --file #{Rails.root.join('docker-compose.timekeeping-demo.yml')} --env-file #{env_file}"

    it "writes the credentials once, readable by its owner only, each value its own" do
      _out, err, status = run("init")
      expect(status).to be_success, err

      values = env_file.readlines(chomp: true).reject { |line| line.start_with?("#") }.to_h { |line| line.split("=", 2) }
      expect(values.keys).to contain_exactly(
        "MIRU_DB_PASSWORD", "MIRU_SECRET_KEY_BASE", "MIRU_SEED_PASSWORD",
        "TIMEKEEPING_DB_PASSWORD", "TIMEKEEPING_SECRET_KEY_BASE", "TIMEKEEPING_TOKEN_KEY"
      )
      expect(values.values.uniq.size).to eq(6)
      expect(values.values).to all(match(/\A[0-9a-f]{32,}\z/))
      expect(env_file.stat.mode & 0o777).to eq(0o600)

      written = env_file.read
      out, _err, status = run("init")
      expect(status).to be_success
      expect(out).to include("left as they are")
      expect(env_file.read).to eq(written)
    end

    it "names every credential the compose file requires" do
      run("init")
      required = compose.fetch("services").values.flat_map { |service| service.fetch("environment", {}).values }
        .flat_map { |value| value.to_s.scan(/\$\{([A-Z0-9_]+):\?/).flatten }.uniq
      written = env_file.readlines(chomp: true).reject { |line| line.start_with?("#") }.map { |line| line.split("=", 2).first }

      expect(required).to match_array(written)
    end

    it "refuses to call docker before the credentials exist" do
      _out, err, status = run("up")

      expect(status).not_to be_success
      expect(err).to include("run bin/timekeeping-demo init first")
      expect(docker_calls).to be_empty
    end

    it "builds both images and starts both applications with only their dedicated workers" do
      run("init")
      _out, err, status = run("up")
      expect(status).to be_success, err

      prefix = "compose --file #{Rails.root.join('docker-compose.timekeeping-demo.yml')} --env-file #{env_file}"
      expect(docker_calls.first(2)).to eq([
        "#{prefix} build miru-web timekeeping-web",
        "#{prefix} up --detach --wait miru-web miru-jobs timekeeping-web timekeeping-relay"
      ])
    end

    it "rebuilds and restarts Timekeeping alone, the web process before its worker" do
      run("init")
      _out, err, status = run("rebuild", "timekeeping")
      expect(status).to be_success, err

      changing = docker_calls.grep(/ (build|up) /)
      expect(changing.map { |call| call.split.last }).to eq(["timekeeping-web", "timekeeping-web", "timekeeping-relay"])
      expect(changing.drop(1)).to all(include("up --detach --wait --no-deps --force-recreate"))
      expect(docker_calls.join("\n")).not_to match(/ (build|up) .*miru-/)
    end

    it "rebuilds and restarts the existing application alone, the web process before its worker" do
      run("init")
      _out, err, status = run("rebuild", "existing")
      expect(status).to be_success, err

      changing = docker_calls.grep(/ (build|up) /)
      expect(changing.map { |call| call.split.last }).to eq(["miru-web", "miru-web", "miru-jobs"])
      expect(changing.drop(1)).to all(include("up --detach --wait --no-deps --force-recreate"))
      expect(docker_calls.join("\n")).not_to match(/ (build|up) .*timekeeping-/)
    end

    it "runs the handoff runners in the existing application, and nothing else" do
      run("init")

      _out, err, status = run("handoff", "rollback:abort")
      expect(status).to be_success, err
      expect(docker_calls.last).to end_with("exec miru-web bin/rails timekeeping:rollback:abort")

      _out, err, status = run("handoff", "db:drop")
      expect(status).not_to be_success
      expect(err).to include("handoff takes first_cutover, rollback or recutover")
      expect(docker_calls.grep(/db:drop/)).to be_empty
    end

    it "runs the end-to-end journey in the existing application" do
      run("init")

      _out, err, status = run("journey")
      expect(status).to be_success, err
      expect(docker_calls.last).to end_with("exec miru-web bin/rails timekeeping:journey")
    end

    it "runs the alternating-writers proof in the existing application" do
      run("init")

      _out, err, status = run("alternating-writers")
      expect(status).to be_success, err
      expect(docker_calls.last).to end_with("exec miru-web bin/rails timekeeping:alternating_writers")
    end

    # The independent-deployment proof (§13 item 4) and its contract check,
    # against a stand-in for docker that keeps one container per service, and
    # gives a service a new container, and so a new image, each time it is
    # recreated. FAKE_ALSO_RECREATE names a service it recreates along with
    # any other; FAKE_TIMEKEEPING_CONTRACTS what Timekeeping's contract
    # documents digest to; FAKE_CHECK_STATUS how timekeeping:contract_check
    # exits. A stopped service is not listed by `ps` until it is started
    # again; FAKE_STOP_IGNORED names one that `stop` leaves running, and
    # FAKE_PAUSED_STATUS how timekeeping:relay_paused:paused exits.
    # FAKE_RELAY is the service timekeeping:user_delete_refused:relay names,
    # after a line of boot noise, and FAKE_REFUSED_STATUS how
    # timekeeping:user_delete_refused:paused exits. `up` starts a stopped
    # service again; FAKE_HELD_STATUS and FAKE_OUTAGE_STATUS are how
    # timekeeping:aggregate_line:held and :outage exit. FAKE_HANDOFF is the
    # task timekeeping:billing_handoff:handoff names, after a line of boot
    # noise; a marker of the billing-handoff run is there unless
    # FAKE_MISSING_MARKER names it; FAKE_BILLING_PAUSED_STATUS and
    # FAKE_BILLING_REFUSED_STATUS are how timekeeping:billing_handoff:paused and
    # :refused exit. A handoff task stops on its first run, as with
    # timekeeping-web stopped, and finishes when run again, unless
    # FAKE_HANDOFF_FINISHES is set, when it finishes at once.
    # FAKE_SAVE_FAILURES_STATUS is how timekeeping:save_failures exits,
    # FAKE_RESERVATION_PAUSED_STATUS how timekeeping:reservation_failures:paused
    # exits, and FAKE_HARD_DELETE_STATUS how timekeeping:hard_delete exits.
    # FAKE_STALE_GENERATION_STATUS is how timekeeping:stale_generation exits,
    # and FAKE_STALE_REFUSED the request ids its last line names;
    # FAKE_TIMEKEEPING_ALERTS the request ids timekeeping-web's log has a
    # stale-generation alert for. timekeeping-relay reaches the projection
    # consumer, answering FAKE_CONSUMER_STATUS (200), until the line naming
    # miru-web is added to its /etc/hosts, and again once it is removed;
    # FAKE_HOSTS_IGNORED leaves it reachable. Its log holds
    # FAKE_REFUSED_DELIVERIES (3) refused deliveries, and Timekeeping's
    # signals count FAKE_UNDELIVERED_DOWN (3) positions undelivered while the
    # consumer is down and FAKE_UNDELIVERED_UP (0) otherwise.
    # FAKE_PROJECTED_STATUS and FAKE_DOWN_STATUS are how
    # timekeeping:consumer_down:projected and :down exit, and
    # FAKE_RESTART_ON_DOWN gives timekeeping-relay a new container during
    # :down.
    context "with running applications" do
      let(:record_dir) { dir.join("deploys") }
      let(:fakes) { {} }

      before do
        dir.join("state").mkpath
        dir.join("bin/docker").write(<<~SH)
          #!/usr/bin/env bash
          echo "$*" >> "#{docker_log}"
          state="#{dir.join('state')}"
          generation() { cat "${state}/$1" 2>/dev/null || echo 1; }
          if [ "$1" = compose ]; then
            shift 5
            case "$1" in
              ps) [ -e "${state}/stopped-${!#}" ] || echo "demo-${!#}-1" ;;
              stop) [ "${!#}" = "${FAKE_STOP_IGNORED:-}" ] || touch "${state}/stopped-${!#}" ;;
              start) rm -f "${state}/stopped-${!#}" ;;
              logs)
                if [ "${!#}" = timekeeping-relay ]; then
                  for _ in $(seq 1 "${FAKE_REFUSED_DELIVERIES:-3}"); do
                    echo "relay: relay 0f0f: Errno::ECONNREFUSED: Failed to open TCP connection to miru-web:3000 (Connection refused)"
                  done
                  echo "relay 0f0f: outbox 1..2, 2 snapshots, requests a, b"
                  exit 0
                fi
                echo "=> Booting Puma"
                for id in ${FAKE_TIMEKEEPING_ALERTS-run-1 run-2}; do
                  echo "[${id}] Timekeeping signal stale_generation: POST /internal/v1/entries was refused with no handoff in progress"
                done ;;
              up)
                rm -f "${state}/stopped-${!#}"
                if [[ " $* " == *" --force-recreate "* ]]; then
                  for service in "${!#}" ${FAKE_ALSO_RECREATE:-}; do echo $(( $(generation "${service}") + 1 )) > "${state}/${service}"; done
                fi ;;
              exec)
                case "$*" in
                  *"--user root timekeeping-relay sh -c printf '127.0.0.1 miru-web"*)
                    [ -n "${FAKE_HOSTS_IGNORED:-}" ] || touch "${state}/consumer-down" ;;
                  *"--user root timekeeping-relay sh -c grep -vF"*) rm -f "${state}/consumer-down" ;;
                  *"-T timekeeping-relay ruby -rnet/http -e"*)
                    if [ -e "${state}/consumer-down" ]; then echo "unreachable Errno::ECONNREFUSED"; else echo "reached ${FAKE_CONSUMER_STATUS:-200}"; fi ;;
                  *"-T timekeeping-web bin/rails timekeeping:signals")
                    echo "ownership: generation 1, owner timekeeping, state open"
                    if [ -e "${state}/consumer-down" ]; then undelivered="${FAKE_UNDELIVERED_DOWN:-3}"; else undelivered="${FAKE_UNDELIVERED_UP:-0}"; fi
                    echo "relay lag: 2.5 s, ${undelivered} position(s) undelivered"
                    echo "no alerts" ;;
                  *timekeeping:consumer_down:projected*)
                    echo "consumer down: projected, consumer down: $([ -e "${state}/consumer-down" ] && echo yes || echo no)"
                    exit "${FAKE_PROJECTED_STATUS:-0}" ;;
                  *timekeeping:consumer_down:down*)
                    echo "consumer down: stale, consumer down: $([ -e "${state}/consumer-down" ] && echo yes || echo no)"
                    [ -z "${FAKE_RESTART_ON_DOWN:-}" ] || echo 2 > "${state}/timekeeping-relay"
                    exit "${FAKE_DOWN_STATUS:-0}" ;;
                  *timekeeping:consumer_down:restored*)
                    echo "consumer down: caught up, consumer down: $([ -e "${state}/consumer-down" ] && echo yes || echo no)" ;;
                  *"sh -c test -f '"*)
                    marker="${!#}"; marker="${marker##*/}"; marker="${marker%?}"
                    [ "${marker}" != "${FAKE_MISSING_MARKER:-}" ]; exit $? ;;
                  *" touch tmp/timekeeping/billing-handoff/"*) touch "${state}/released" ;;
                  *timekeeping:billing_handoff:handoff*) echo "booting"; echo "${FAKE_HANDOFF-timekeeping:rollback}" ;;
                  *timekeeping:billing_handoff:paused*)
                    echo "billing handoff: paused"
                    exit "${FAKE_BILLING_PAUSED_STATUS:-0}" ;;
                  *timekeeping:billing_handoff:refused*)
                    echo "billing handoff: refused, timekeeping-web stopped: $([ -e "${state}/stopped-timekeeping-web" ] && echo yes || echo no)"
                    exit "${FAKE_BILLING_REFUSED_STATUS:-0}" ;;
                  *timekeeping:billing_handoff:resumed*) echo "billing handoff: accepted again" ;;
                  *"-T miru-web bin/rails timekeeping:rollback"|*"-T miru-web bin/rails timekeeping:first_cutover"|*"-T miru-web bin/rails timekeeping:recutover")
                    if [ -z "${FAKE_HANDOFF_FINISHES:-}" ] && [ ! -e "${state}/handoff-stopped" ]; then
                      touch "${state}/handoff-stopped"
                      echo "Timekeeping handoff stopped: Unavailable"; exit 1
                    fi
                    echo "Timekeeping handoff: done" ;;
                  *"timekeeping-web sh -c"*) echo "${FAKE_TIMEKEEPING_CONTRACTS:-0a1b  entry_api.json}" ;;
                  *"miru-web sh -c"*) echo "0a1b  entry_api.json" ;;
                  *timekeeping:contract_check*) echo "contract check: every contract held"; exit "${FAKE_CHECK_STATUS:-0}" ;;
                  *timekeeping:relay_paused:paused*)
                    echo "relay paused: listed and invoiced at once, relay stopped: $([ -e "${state}/stopped-timekeeping-relay" ] && echo yes || echo no)"
                    exit "${FAKE_PAUSED_STATUS:-0}" ;;
                  *timekeeping:relay_paused:resumed*)
                    echo "relay paused: caught up, relay stopped: $([ -e "${state}/stopped-timekeeping-relay" ] && echo yes || echo no)" ;;
                  *timekeeping:user_delete_refused:relay*) echo "booting"; echo "${FAKE_RELAY-timekeeping-relay}" ;;
                  *timekeeping:user_delete_refused:paused*)
                    for service in timekeeping-relay miru-jobs; do
                      echo "user delete: refused, ${service} stopped: $([ -e "${state}/stopped-${service}" ] && echo yes || echo no)"
                    done
                    exit "${FAKE_REFUSED_STATUS:-0}" ;;
                  *timekeeping:save_failures*)
                    echo "save failures: every case held"
                    exit "${FAKE_SAVE_FAILURES_STATUS:-0}" ;;
                  *timekeeping:stale_generation*)
                    echo "stale generation: every case held"
                    echo "stale generation: refused request ids: ${FAKE_STALE_REFUSED-run-1 run-2}"
                    exit "${FAKE_STALE_GENERATION_STATUS:-0}" ;;
                  *timekeeping:hard_delete*)
                    echo "hard delete: every case held"
                    exit "${FAKE_HARD_DELETE_STATUS:-0}" ;;
                  *timekeeping:reservation_failures:paused*)
                    echo "reservation failures: refused and lost, miru-jobs stopped: $([ -e "${state}/stopped-miru-jobs" ] && echo yes || echo no)"
                    exit "${FAKE_RESERVATION_PAUSED_STATUS:-0}" ;;
                  *timekeeping:reservation_failures:resumed*)
                    echo "reservation failures: delivered and retried, miru-jobs stopped: $([ -e "${state}/stopped-miru-jobs" ] && echo yes || echo no)" ;;
                  *timekeeping:aggregate_line:held*)
                    echo "aggregate line: held, timekeeping-web stopped: $([ -e "${state}/stopped-timekeeping-web" ] && echo yes || echo no)"
                    exit "${FAKE_HELD_STATUS:-0}" ;;
                  *timekeeping:aggregate_line:outage*)
                    echo "aggregate line: failed, timekeeping-web stopped: $([ -e "${state}/stopped-timekeeping-web" ] && echo yes || echo no)"
                    exit "${FAKE_OUTAGE_STATUS:-0}" ;;
                  *timekeeping:aggregate_line:restored*)
                    echo "aggregate line: released, timekeeping-web stopped: $([ -e "${state}/stopped-timekeeping-web" ] && echo yes || echo no)" ;;
                  *timekeeping:user_delete_refused:resumed*)
                    for service in timekeeping-relay miru-jobs; do
                      echo "user delete: projected, ${service} stopped: $([ -e "${state}/stopped-${service}" ] && echo yes || echo no)"
                    done ;;
                esac ;;
            esac
            exit 0
          fi
          service="${!##demo-}"
          service="${service%-1}"
          case "$1 $2" in
            "inspect --format={{.Id}}") echo "${service}-container-$(generation "${service}")" ;;
            "inspect --format={{.Image}}") echo "image-of-${service}-container-$(generation "${service}")" ;;
            "image inspect") echo "revision-of-${!#}" ;;
          esac
        SH
        run("init")
      end

      def run(*args)
        Open3.capture3(
          { "TIMEKEEPING_DEMO_ENV_FILE" => env_file.to_s, "TIMEKEEPING_DEMO_RECORD_DIR" => record_dir.to_s,
            "PATH" => "#{dir.join('bin')}:#{ENV.fetch('PATH')}" }.merge(fakes),
          script, *args
        )
      end

      def records = record_dir.glob("*.log")

      it "checks that both applications read the same contract documents, then runs the contract check in the existing application" do
        out, err, status = run("contract-check")

        expect(status).to be_success, err
        expect(docker_calls.grep(/ exec /)).to eq([
          "#{prefix} exec -T miru-web sh -c cd '/rails/packages/timekeeping_reservations/contracts/v1' && sha256sum *.json",
          "#{prefix} exec -T timekeeping-web sh -c cd '/app/packages/timekeeping_reservations/contracts/v1' && sha256sum *.json",
          "#{prefix} exec -T miru-web bin/rails timekeeping:contract_check"
        ])
        expect(out).to include("both applications read the same 1 files", "every contract held")
      end

      context "when the two applications read different contract documents" do
        let(:fakes) { { "FAKE_TIMEKEEPING_CONTRACTS" => "9f9f  entry_api.json" } }

        it "fails without running the contract check" do
          _out, err, status = run("contract-check")

          expect(status).not_to be_success
          expect(err).to include("the two applications do not read the same contract documents", "9f9f  entry_api.json")
          expect(docker_calls.grep(/timekeeping:contract_check/)).to be_empty
        end
      end

      it "rebuilds and restarts Timekeeping alone, then the existing application alone, with the contract check before and after each" do
        out, err, status = run("independent-deploys")
        expect(status).to be_success, err

        steps = docker_calls.filter_map do |call|
          case call
          when / build (\S+)\z/ then "build #{Regexp.last_match(1)}"
          when / up .*--force-recreate (\S+)\z/ then "restart #{Regexp.last_match(1)}"
          when /timekeeping:contract_check/ then "contract check"
          end
        end
        expect(steps).to eq([
          "contract check",
          "build timekeeping-web", "restart timekeeping-web", "restart timekeeping-relay", "contract check",
          "build miru-web", "restart miru-web", "restart miru-jobs", "contract check"
        ])
        expect(out).to include(
          "the existing application stayed at its prior artifact:\n" \
          "miru-web container=miru-web-container-1 image=image-of-miru-web-container-1 revision=revision-of-image-of-miru-web-container-1",
          "Timekeeping stayed at its prior artifact:\n" \
          "timekeeping-web container=timekeeping-web-container-2 image=image-of-timekeeping-web-container-2"
        )

        expect(records.size).to eq(1)
        record = records.first.read
        expect(record).to include(
          "== before the deploys", "timekeeping-relay container=timekeeping-relay-container-1",
          "== deploy: timekeeping, alone", "timekeeping now runs:\ntimekeeping-web container=timekeeping-web-container-2",
          "== deploy: existing, alone", "existing now runs:\nmiru-web container=miru-web-container-2",
          "miru-jobs container=miru-jobs-container-2",
          "the contract check green after each"
        )
        expect(out).to include("Recorded in #{records.first}.")
      end

      context "when a deploy also restarts the other application" do
        let(:fakes) { { "FAKE_ALSO_RECREATE" => "miru-jobs" } }

        it "fails the proof at the first deploy, and records why" do
          _out, _err, status = run("independent-deploys")

          expect(status).not_to be_success
          expect(records.first.read).to include(
            "rebuilding timekeeping changed the existing application",
            # Recreated along with each of Timekeeping's two processes.
            "miru-jobs container=miru-jobs-container-1", "miru-jobs container=miru-jobs-container-3"
          )
          expect(docker_calls.grep(/ build miru-web/)).to be_empty
        end
      end

      context "when the contract check fails" do
        let(:fakes) { { "FAKE_CHECK_STATUS" => "1" } }

        it "fails the proof before any deploy" do
          _out, _err, status = run("independent-deploys")

          expect(status).not_to be_success
          expect(docker_calls.grep(/ build /)).to be_empty
          expect(records.first.read).not_to include("independent deploys done")
        end
      end

      describe "the relay-paused proof (§13 item 5)" do
        def steps
          docker_calls.filter_map do |call|
            case call
            when / (stop|start) timekeeping-relay\z/ then "#{Regexp.last_match(1)} relay"
            when /exec -T --env RUN=(\S+) miru-web bin\/rails timekeeping:relay_paused:(\w+)\z/ then "#{Regexp.last_match(2)} #{Regexp.last_match(1)}"
            end
          end
        end

        it "stops Timekeeping's relay, runs the paused half, starts the relay, then runs the resumed half under the same run" do
          out, err, status = run("relay-paused")
          expect(status).to be_success, err

          run_name = steps.second.split.last
          expect(run_name).to match(/\A\d{8}T\d{6}Z-\h{4}\z/)
          expect(steps).to eq(["stop relay", "paused #{run_name}", "start relay", "resumed #{run_name}"])
          expect(out).to include(
            "relay paused: listed and invoiced at once, relay stopped: yes",
            "timekeeping-relay container=timekeeping-relay-container-1",
            "relay paused: caught up, relay stopped: no",
            "the projection caught up once it resumed"
          )
          expect(docker_calls.join("\n")).not_to match(/ (stop|start|up|build) .*miru-/)
        end

        context "when the paused half fails" do
          let(:fakes) { { "FAKE_PAUSED_STATUS" => "1" } }

          it "starts the relay again and does not run the resumed half" do
            _out, _err, status = run("relay-paused")

            expect(status).not_to be_success
            expect(steps.map(&:split).map(&:first)).to eq(%w[stop paused start])
          end
        end

        context "when the relay keeps running after it is stopped" do
          let(:fakes) { { "FAKE_STOP_IGNORED" => "timekeeping-relay" } }

          it "fails before either half, since nothing would be paused" do
            _out, err, status = run("relay-paused")

            expect(status).not_to be_success
            expect(err).to include("timekeeping-relay still runs after it was stopped")
            expect(steps).to eq(["stop relay", "start relay"])
          end
        end

        it "fails before stopping anything when a process is not running" do
          dir.join("bin/docker").write("#!/bin/sh\necho \"$*\" >> \"#{docker_log}\"\n")

          _out, err, status = run("relay-paused")

          expect(status).not_to be_success
          expect(err).to include("miru-web is not running")
          expect(steps).to be_empty
        end
      end

      describe "the user-hard-delete proof (§12.4)" do
        def steps
          docker_calls.filter_map do |call|
            case call
            when / (stop|start) (timekeeping-relay|miru-jobs)\z/ then "#{Regexp.last_match(1)} #{Regexp.last_match(2)}"
            when /exec -T --env RUN=(\S+) miru-web bin\/rails timekeeping:user_delete_refused:(\w+)\z/ then "#{Regexp.last_match(2)} #{Regexp.last_match(1)}"
            end
          end
        end

        it "asks which relay to pause, stops it, runs the paused half, starts it, then runs the resumed half under the same run" do
          out, err, status = run("user-delete-refused")
          expect(status).to be_success, err

          run_name = steps.first.split.last
          expect(run_name).to match(/\A\d{8}T\d{6}Z-\h{4}\z/)
          expect(steps).to eq([
            "relay #{run_name}", "stop timekeeping-relay", "paused #{run_name}", "start timekeeping-relay", "resumed #{run_name}"
          ])
          expect(out).to include(
            "pausing the owner's relay (timekeeping-relay)",
            "user delete: refused, timekeeping-relay stopped: yes",
            "user delete: projected, timekeeping-relay stopped: no",
            "the entry was projected once timekeeping-relay resumed"
          )
          expect(docker_calls.join("\n")).not_to match(/ (stop|start|up|build) .*miru-/)
        end

        context "when the prepared application owns the entries" do
          let(:fakes) { { "FAKE_RELAY" => "miru-jobs" } }

          it "pauses miru-jobs, which runs its local relay, and leaves Timekeeping's relay running" do
            out, err, status = run("user-delete-refused")
            expect(status).to be_success, err

            expect(steps.grep(/\A(stop|start) /)).to eq(["stop miru-jobs", "start miru-jobs"])
            expect(out).to include(
              "user delete: refused, miru-jobs stopped: yes", "user delete: refused, timekeeping-relay stopped: no",
              "user delete: projected, miru-jobs stopped: no"
            )
          end
        end

        context "when the paused half fails" do
          let(:fakes) { { "FAKE_REFUSED_STATUS" => "1" } }

          it "starts the relay again and does not run the resumed half" do
            _out, _err, status = run("user-delete-refused")

            expect(status).not_to be_success
            expect(steps.map(&:split).map(&:first)).to eq(%w[relay stop paused start])
          end
        end

        context "when the existing application names no relay" do
          let(:fakes) { { "FAKE_RELAY" => "" } }

          it "fails before stopping anything" do
            _out, err, status = run("user-delete-refused")

            expect(status).not_to be_success
            expect(err).to include("named no relay to pause")
            expect(steps.map(&:split).map(&:first)).to eq(%w[relay])
          end
        end

        context "when the relay keeps running after it is stopped" do
          let(:fakes) { { "FAKE_STOP_IGNORED" => "timekeeping-relay" } }

          it "fails before either half, since nothing would be paused" do
            _out, err, status = run("user-delete-refused")

            expect(status).not_to be_success
            expect(err).to include("timekeeping-relay still runs after it was stopped")
            expect(steps.map(&:split).map(&:first)).to eq(%w[relay stop start])
          end
        end
      end

      describe "the aggregate-line proof (§12.4, F3)" do
        def steps
          docker_calls.filter_map do |call|
            case call
            when / stop timekeeping-web\z/ then "stop web"
            when / up --detach --wait --no-deps --no-recreate timekeeping-web\z/ then "start web"
            when /exec -T --env RUN=(\S+) miru-web bin\/rails timekeeping:aggregate_line:(\w+)\z/ then "#{Regexp.last_match(2)} #{Regexp.last_match(1)}"
            end
          end
        end

        it "runs the held step, stops timekeeping-web, runs the outage step, starts it again, then runs the restored step under one run" do
          out, err, status = run("aggregate-line")
          expect(status).to be_success, err

          run_name = steps.first.split.last
          expect(run_name).to match(/\A\d{8}T\d{6}Z-\h{4}\z/)
          expect(steps).to eq(["held #{run_name}", "stop web", "outage #{run_name}", "start web", "restored #{run_name}"])
          expect(out).to include(
            "aggregate line: held, timekeeping-web stopped: no",
            "aggregate line: failed, timekeeping-web stopped: yes",
            "timekeeping-web container=timekeeping-web-container-1",
            "aggregate line: released, timekeeping-web stopped: no",
            "destroying the draft released its whole set"
          )
          expect(docker_calls.join("\n")).not_to match(/ (stop|start|up|build) .*(miru-|timekeeping-relay)/)
        end

        context "when the held step fails" do
          let(:fakes) { { "FAKE_HELD_STATUS" => "1" } }

          it "stops nothing and runs no other step" do
            _out, _err, status = run("aggregate-line")

            expect(status).not_to be_success
            expect(steps.map(&:split).map(&:first)).to eq(%w[held])
          end
        end

        context "when the outage step fails" do
          let(:fakes) { { "FAKE_OUTAGE_STATUS" => "1" } }

          it "starts timekeeping-web again and does not run the restored step" do
            _out, _err, status = run("aggregate-line")

            expect(status).not_to be_success
            expect(steps.map(&:split).map(&:first)).to eq(%w[held stop outage start])
          end
        end

        context "when timekeeping-web keeps running after it is stopped" do
          let(:fakes) { { "FAKE_STOP_IGNORED" => "timekeeping-web" } }

          it "fails before the outage step, since nothing would fail" do
            _out, err, status = run("aggregate-line")

            expect(status).not_to be_success
            expect(err).to include("timekeeping-web still runs after it was stopped")
            expect(steps.map(&:split).map(&:first)).to eq(%w[held stop start])
          end
        end
      end

      describe "the save-failure part of the failure injection (§12.4, §9.3)" do
        it "runs the one step in the existing application under a run name, and stops and starts nothing" do
          out, err, status = run("save-failures")
          expect(status).to be_success, err

          step = docker_calls.grep(/timekeeping:save_failures/).sole
          expect(step).to match(/exec -T --env RUN=\d{8}T\d{6}Z-\h{4} miru-web bin\/rails timekeeping:save_failures\z/)
          expect(out).to include("save failures: every case held", "no replay of a resolved operation changed anything")
          expect(docker_calls.join("\n")).not_to match(/ (stop|start|up|build|kill) /)
        end

        context "when the step fails" do
          let(:fakes) { { "FAKE_SAVE_FAILURES_STATUS" => "1" } }

          it "fails, and says nothing held" do
            out, _err, status = run("save-failures")

            expect(status).not_to be_success
            expect(out).not_to include("no replay of a resolved operation changed anything")
          end
        end

        context "when a process is not running" do
          it "runs nothing" do
            run("compose", "stop", "timekeeping-web")
            _out, err, status = run("save-failures")

            expect(status).not_to be_success
            expect(err).to include("timekeeping-web is not running")
            expect(docker_calls.grep(/timekeeping:save_failures/)).to be_empty
          end
        end
      end

      describe "the hard-delete-of-a-non-draft part of the failure injection (§12.4, §9.3)" do
        it "runs the one step in the existing application under a run name, and stops and starts nothing" do
          out, err, status = run("hard-delete")
          expect(status).to be_success, err

          step = docker_calls.grep(/timekeeping:hard_delete/).sole
          expect(step).to match(/exec -T --env RUN=\d{8}T\d{6}Z-\h{4} miru-web bin\/rails timekeeping:hard_delete\z/)
          expect(out).to include("hard delete: every case held", "kept the edit lock until a successor took the entry over")
          expect(docker_calls.join("\n")).not_to match(/ (stop|start|up|build|kill) /)
        end

        context "when the step fails" do
          let(:fakes) { { "FAKE_HARD_DELETE_STATUS" => "1" } }

          it "fails, and says nothing held" do
            out, _err, status = run("hard-delete")

            expect(status).not_to be_success
            expect(out).not_to include("kept the edit lock until a successor took the entry over")
          end
        end

        context "when a process is not running" do
          it "runs nothing" do
            run("compose", "stop", "miru-jobs")
            _out, err, status = run("hard-delete")

            expect(status).not_to be_success
            expect(err).to include("miru-jobs is not running")
            expect(docker_calls.grep(/timekeeping:hard_delete/)).to be_empty
          end
        end
      end

      describe "the stale-generation part of the failure injection (§12.4, §9.3)" do
        it "runs the one step in the existing application, then finds Timekeeping's alert for each refused request, and stops and starts nothing" do
          out, err, status = run("stale-generation")
          expect(status).to be_success, err

          step = docker_calls.grep(/timekeeping:stale_generation/).sole
          expect(step).to match(/exec -T --env RUN=\d{8}T\d{6}Z-\h{4} miru-web bin\/rails timekeeping:stale_generation\z/)
          expect(docker_calls.last).to end_with("logs --no-color --no-log-prefix timekeeping-web")
          expect(out).to include("stale generation: every case held", "Timekeeping reported each of the 2 refusals as an alert")
          expect(docker_calls.join("\n")).not_to match(/ (stop|start|up|build|kill) /)

          run_name = step[/RUN=(\S+)/, 1]
          expect(dir.join("stale-generation/#{run_name}.log").read).to include("stale generation: refused request ids: run-1 run-2")
        end

        context "when timekeeping-web's log has no alert for a refused request" do
          let(:fakes) { { "FAKE_TIMEKEEPING_ALERTS" => "run-1" } }

          it "fails, naming the request" do
            out, err, status = run("stale-generation")

            expect(status).not_to be_success
            expect(err).to include("timekeeping-web's log has no stale-generation alert for request run-2 (§11.3)")
            expect(out).not_to include("refusals as an alert")
          end
        end

        context "when the step names no refused request" do
          let(:fakes) { { "FAKE_STALE_REFUSED" => "" } }

          it "fails without reading the log" do
            _out, err, status = run("stale-generation")

            expect(status).not_to be_success
            expect(err).to include("the stale-generation step named no refused request")
            expect(docker_calls.grep(/ logs /)).to be_empty
          end
        end

        context "when the step fails" do
          let(:fakes) { { "FAKE_STALE_GENERATION_STATUS" => "1" } }

          it "fails without reading the log" do
            out, _err, status = run("stale-generation")

            expect(status).not_to be_success
            expect(docker_calls.grep(/ logs /)).to be_empty
            expect(out).not_to include("refusals as an alert")
          end
        end

        context "when a process is not running" do
          it "runs nothing" do
            run("compose", "stop", "timekeeping-relay")
            _out, err, status = run("stale-generation")

            expect(status).not_to be_success
            expect(err).to include("timekeeping-relay is not running")
            expect(docker_calls.grep(/timekeeping:stale_generation/)).to be_empty
          end
        end
      end

      describe "the projection-consumer-down part of the failure injection (§12.4, §9.3)" do
        def steps
          docker_calls.filter_map do |call|
            case call
            when /exec -T --env RUN=(\S+) miru-web bin\/rails timekeeping:consumer_down:(\w+)\z/ then "#{Regexp.last_match(2)} #{Regexp.last_match(1)}"
            when /exec -T --user root timekeeping-relay sh -c printf '127\.0\.0\.1 miru-web # %s\\n' 'bin\/timekeeping-demo consumer-down' >> \/etc\/hosts\z/
              "take down"
            when /exec -T --user root timekeeping-relay sh -c grep -vF 'bin\/timekeeping-demo consumer-down' \/etc\/hosts > /
              "bring back"
            when /exec -T timekeeping-relay ruby -rnet\/http -e/ then "probe"
            when /logs --no-color --no-log-prefix --since \d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ timekeeping-relay\z/ then "relay log"
            when /exec -T timekeeping-web bin\/rails timekeeping:signals\z/ then "signals"
            end
          end
        end

        it "takes the consumer down for the relay around the down step, without stopping or restarting anything, under one run name" do
          out, err, status = run("consumer-down")
          expect(status).to be_success, err

          run_name = steps.first(2).last[/\Aprojected (\S+)\z/, 1]
          expect(run_name).to match(/\A\d{8}T\d{6}Z-\h{4}\z/)
          expect(steps).to eq([
            "probe", "projected #{run_name}", "take down", "probe", "down #{run_name}", "relay log", "signals",
            "bring back", "probe", "restored #{run_name}", "signals"
          ])
          expect(out).to include(
            "consumer down: projected, consumer down: no", "consumer down: stale, consumer down: yes",
            "the projection consumer is unreachable Errno::ECONNREFUSED", "3 deliveries refused while the consumer was down",
            "consumer down: caught up, consumer down: no", "the same relay delivered every snapshot"
          )
          expect(err).to include("relay lag: 2.5 s, 3 position(s) undelivered", "relay lag: 2.5 s, 0 position(s) undelivered")
          expect(docker_calls.join("\n")).not_to match(/ (stop|start|up|build|kill|restart) /)
        end

        context "when the down step fails" do
          let(:fakes) { { "FAKE_DOWN_STATUS" => "1" } }

          it "still brings the consumer back, and does not run the restored step" do
            _out, _err, status = run("consumer-down")

            expect(status).not_to be_success
            expect(steps.last(2)).to eq(["down #{steps[1][/\S+\z/]}", "bring back"])
            expect(dir.join("state/consumer-down")).not_to exist
          end
        end

        context "when the relay still reaches the consumer after it was taken down" do
          let(:fakes) { { "FAKE_HOSTS_IGNORED" => "1" } }

          it "fails before the down step, and brings the consumer back" do
            _out, err, status = run("consumer-down")

            expect(status).not_to be_success
            expect(err).to include("timekeeping-relay still reaches the projection consumer after it was taken down: reached 200")
            expect(steps.grep(/\Adown /)).to be_empty
            expect(steps.last).to eq("bring back")
          end
        end

        context "when the relay does not reach the consumer before the run" do
          let(:fakes) { { "FAKE_CONSUMER_STATUS" => "502" } }

          it "runs nothing" do
            _out, err, status = run("consumer-down")

            expect(status).not_to be_success
            expect(err).to include("timekeeping-relay does not reach the projection consumer before the run: reached 502")
            expect(steps).to eq(["probe"])
          end
        end

        context "when the relay's log shows fewer than two refused deliveries" do
          let(:fakes) { { "FAKE_REFUSED_DELIVERIES" => "1" } }

          it "fails, brings the consumer back, and does not run the restored step" do
            _out, err, status = run("consumer-down")

            expect(status).not_to be_success
            expect(err).to include("timekeeping-relay's log shows 1 refused deliveries while the consumer was down")
            expect(steps.last).to eq("bring back")
            expect(steps.grep(/\Arestored /)).to be_empty
          end
        end

        context "when Timekeeping counts nothing undelivered while the consumer is down" do
          let(:fakes) { { "FAKE_UNDELIVERED_DOWN" => "0" } }

          it "fails, and brings the consumer back" do
            _out, err, status = run("consumer-down")

            expect(status).not_to be_success
            expect(err).to include("Timekeeping counts no snapshot undelivered while the consumer is down")
            expect(steps.last).to eq("bring back")
          end
        end

        context "when snapshots are still undelivered after the consumer came back" do
          let(:fakes) { { "FAKE_UNDELIVERED_UP" => "2" } }

          it "fails after the restored step" do
            out, err, status = run("consumer-down")

            expect(status).not_to be_success
            expect(err).to include("Timekeeping still counts 2 snapshots undelivered after the consumer came back")
            expect(out).not_to include("the same relay delivered every snapshot")
          end
        end

        context "when a process is restarted while the consumer is down" do
          let(:fakes) { { "FAKE_RESTART_ON_DOWN" => "1" } }

          it "fails before the restored step" do
            _out, err, status = run("consumer-down")

            expect(status).not_to be_success
            expect(err).to include("a process was restarted while the consumer was down")
            expect(steps.grep(/\Arestored /)).to be_empty
          end
        end

        context "when a process is not running" do
          it "runs nothing" do
            run("compose", "stop", "timekeeping-relay")
            _out, err, status = run("consumer-down")

            expect(status).not_to be_success
            expect(err).to include("timekeeping-relay is not running")
            expect(steps).to be_empty
          end
        end
      end

      describe "the reservation-protocol part of the failure injection (§12.4, §9.3)" do
        def steps
          docker_calls.filter_map do |call|
            case call
            when / (stop|start) (miru-jobs|timekeeping-relay|timekeeping-web)\z/ then "#{Regexp.last_match(1)} #{Regexp.last_match(2)}"
            when /exec -T --env RUN=(\S+) miru-web bin\/rails timekeeping:reservation_failures:(\w+)\z/ then "#{Regexp.last_match(2)} #{Regexp.last_match(1)}"
            end
          end
        end

        it "stops miru-jobs, runs the paused step, starts miru-jobs, then runs the resumed step under the same run" do
          out, err, status = run("reservation-failures")
          expect(status).to be_success, err

          run_name = steps.second.split.last
          expect(run_name).to match(/\A\d{8}T\d{6}Z-\h{4}\z/)
          expect(steps).to eq(["stop miru-jobs", "paused #{run_name}", "start miru-jobs", "resumed #{run_name}"])
          expect(out).to include(
            "reservation failures: refused and lost, miru-jobs stopped: yes",
            "miru-jobs container=miru-jobs-container-1",
            "reservation failures: delivered and retried, miru-jobs stopped: no",
            "the retry went through once miru-jobs resumed"
          )
          expect(docker_calls.join("\n")).not_to match(/ (stop|start|up|build) .*(timekeeping-|miru-web)/)
        end

        context "when the paused step fails" do
          let(:fakes) { { "FAKE_RESERVATION_PAUSED_STATUS" => "1" } }

          it "starts miru-jobs again and does not run the resumed step" do
            _out, _err, status = run("reservation-failures")

            expect(status).not_to be_success
            expect(steps.map(&:split).map(&:first)).to eq(%w[stop paused start])
          end
        end

        context "when miru-jobs keeps running after it is stopped" do
          let(:fakes) { { "FAKE_STOP_IGNORED" => "miru-jobs" } }

          it "fails before either step, since nothing would be left undelivered" do
            _out, err, status = run("reservation-failures")

            expect(status).not_to be_success
            expect(err).to include("miru-jobs still runs after it was stopped")
            expect(steps).to eq(["stop miru-jobs", "start miru-jobs"])
          end
        end

        it "fails before stopping anything when a process is not running" do
          run("compose", "stop", "timekeeping-relay")
          _out, err, status = run("reservation-failures")

          expect(status).not_to be_success
          expect(err).to include("timekeeping-relay is not running")
          expect(steps).to eq(["stop timekeeping-relay"])
        end
      end

      describe "the billing-writes-during-a-handoff proof (§12.4)" do
        let(:marker_dir) { "tmp/timekeeping/billing-handoff" }

        def steps
          docker_calls.filter_map do |call|
            case call
            when /exec -T --env RUN=(\S+) miru-web bin\/rails timekeeping:billing_handoff:(\w+)\z/
              "#{Regexp.last_match(2)} #{Regexp.last_match(1)}"
            when /exec -T miru-web sh -c test -f '#{marker_dir}\/\S+\/(\w+)'\z/ then "marker #{Regexp.last_match(1)}"
            when /exec -T miru-web touch #{marker_dir}\/\S+\/release\z/ then "release"
            when /exec -T miru-web bin\/rails (timekeeping:\w+)\z/ then Regexp.last_match(1)
            when / stop timekeeping-web\z/ then "stop web"
            when / up --detach --wait --no-deps --no-recreate timekeeping-web\z/ then "start web"
            end
          end
        end

        def kinds = steps.map { |step| step.split.first }

        # The paused write and the handoff's first run go to the background,
        # so where their calls land among the script's own is not fixed: these
        # are the calls the script makes in turn, which keep their order.
        def foreground
          in_turn = steps.reject { |step| step.start_with?("paused ") }
          first_run = in_turn.index { |step| step.start_with?("timekeeping:") }
          in_turn.tap { |calls| calls.delete_at(first_run) if first_run }
        end

        def foreground_kinds = foreground.map { |step| step.split.first }

        it "pauses a billing write, starts the handoff it waits on, stops timekeeping-web, releases the write, runs the refused " \
           "step, starts timekeeping-web again, resumes the handoff and runs the resumed step, under one run" do
          out, err, status = run("billing-handoff")
          expect(status).to be_success, err

          run_name = steps.first.split.last
          expect(run_name).to match(/\A\d{8}T\d{6}Z-\h{4}\z/)
          expect(steps).to include("paused #{run_name}")
          expect(steps.count("timekeeping:rollback")).to eq(2)
          expect(foreground).to eq([
            "handoff #{run_name}", "marker admitted", "marker waiting", "stop web", "release", "refused #{run_name}",
            "start web", "timekeeping:rollback", "resumed #{run_name}"
          ])
          expect(out).to include(
            "handing over with timekeeping:rollback",
            "Timekeeping handoff stopped: Unavailable",
            "billing handoff: refused, timekeeping-web stopped: yes",
            "Timekeeping handoff: done",
            "billing handoff: accepted again",
            "billing writes were refused with 503 ownership-moving while it ran"
          )
          expect(dir.join("billing-handoff/#{run_name}.log").read).to include("Timekeeping handoff stopped: Unavailable")
          expect(docker_calls.join("\n")).not_to match(/ (stop|start|up|build) .*(miru-|timekeeping-relay)/)
        end

        context "when the existing application names the re-cutover" do
          let(:fakes) { { "FAKE_HANDOFF" => "timekeeping:recutover" } }

          it "runs that handoff, and resumes it" do
            _out, err, status = run("billing-handoff")

            expect(status).to be_success, err
            expect(kinds.grep(/\Atimekeeping:/)).to eq(%w[timekeeping:recutover timekeeping:recutover])
          end
        end

        context "when the existing application names no handoff" do
          let(:fakes) { { "FAKE_HANDOFF" => "" } }

          it "pauses no billing write" do
            _out, err, status = run("billing-handoff")

            expect(status).not_to be_success
            expect(err).to include("the existing application named no handoff to run: nothing")
            expect(kinds).to eq(%w[handoff])
          end
        end

        context "when the paused billing write ends without being admitted" do
          let(:fakes) { { "FAKE_MISSING_MARKER" => "admitted", "FAKE_BILLING_PAUSED_STATUS" => "1" } }

          it "starts no handoff and stops nothing" do
            _out, err, status = run("billing-handoff")

            expect(status).not_to be_success
            expect(err).to include("the paused billing write was never admitted")
            expect(kinds).to include("paused")
            expect(foreground_kinds.uniq).to eq(%w[handoff marker])
            expect(kinds.grep(/\Atimekeeping:/)).to be_empty
          end
        end

        context "when the handoff is never seen waiting on the paused billing write" do
          let(:fakes) { { "FAKE_MISSING_MARKER" => "waiting", "FAKE_BILLING_PAUSED_STATUS" => "1" } }

          it "stops nothing and releases nothing" do
            _out, err, status = run("billing-handoff")

            expect(status).not_to be_success
            expect(err).to include("the handoff's step 1 was never seen waiting on the paused billing write")
            expect(kinds).not_to include("stop", "release", "refused")
          end
        end

        context "when the handoff finishes while timekeeping-web is stopped" do
          let(:fakes) { { "FAKE_HANDOFF_FINISHES" => "1" } }

          it "fails before the refused step, and starts timekeeping-web again" do
            _out, err, status = run("billing-handoff")

            expect(status).not_to be_success
            expect(err).to include("timekeeping:rollback finished while timekeeping-web was stopped")
            expect(foreground_kinds.last(3)).to eq(%w[stop release start])
          end
        end

        context "when the refused step fails" do
          let(:fakes) { { "FAKE_BILLING_REFUSED_STATUS" => "1" } }

          it "starts timekeeping-web again and does not resume the handoff" do
            _out, _err, status = run("billing-handoff")

            expect(status).not_to be_success
            expect(foreground_kinds.last(3)).to eq(%w[release refused start])
            expect(kinds.grep(/\Atimekeeping:/).size).to eq(1)
          end
        end
      end

      it "fails when a process is not running" do
        dir.join("bin/docker").write("#!/bin/sh\necho \"$*\" >> \"#{docker_log}\"\n")

        _out, _err, status = run("independent-deploys")

        expect(status).not_to be_success
        expect(records.first.read).to include("miru-web is not running; start the demo with bin/timekeeping-demo up")
        expect(docker_calls.grep(/ build /)).to be_empty
      end
    end
  end
end
