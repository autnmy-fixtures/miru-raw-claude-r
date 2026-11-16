# frozen_string_literal: true

require "rails_helper"
require "open3"
require "tmpdir"

# Timekeeping's own CI, services/timekeeping/bin/ci
# (docs/architecture/timekeeping-soa.md §12.3 "Provider tests run against the
# schema in Timekeeping's CI", §14 "Deployment and runtime": the second image
# and its CI build job). The image step runs here against stand-ins for
# docker, curl and sleep that record what they were asked, so nothing builds
# an image or starts a container.
RSpec.describe "Timekeeping CI script" do
  let(:script) { Rails.root.join("services/timekeeping/bin/ci").to_s }
  let(:bin) { Dir.mktmpdir("timekeeping-ci-bin") }
  let(:log) { File.join(bin, "docker.log") }
  let(:env_copies) { File.join(bin, "env") }
  let(:database_url) { "postgres://timekeeping:password@127.0.0.1:5432/timekeeping_production" }
  let(:fakes) { {} }

  before do
    FileUtils.mkdir_p(env_copies)
    stub_command("docker", <<~'SH')
      echo "$*" >> "${FAKE_LOG}"
      case "$1" in
        build) exit "${FAKE_BUILD_STATUS:-0}" ;;
        image) echo "${FAKE_LABEL}" ;;
        inspect)
          case "${!#}" in
            timekeeping-ci-web) echo "${FAKE_WEB_RUNNING:-true}" ;;
            *) echo "${FAKE_RELAY_RUNNING:-true}" ;;
          esac ;;
        run)
          previous=""
          for arg in "$@"; do
            if [ "${previous}" = "--env-file" ]; then
              echo "${arg}" >> "${FAKE_ENV_COPIES}/paths"
              cp "${arg}" "${FAKE_ENV_COPIES}/$(wc -l < "${FAKE_ENV_COPIES}/paths" | tr -d ' ')"
            fi
            previous="${arg}"
          done
          echo container-id ;;
        exec) exit "${FAKE_EXEC_STATUS:-0}" ;;
        logs) echo "logs of ${!#}" ;;
      esac
    SH
    stub_command("curl", 'echo "$*" >> "${FAKE_LOG}.curl"; exit "${FAKE_CURL_STATUS:-0}"')
    stub_command("sleep", "exit 0")
  end

  after { FileUtils.rm_rf(bin) }

  def stub_command(name, body)
    path = File.join(bin, name)
    File.write(path, "#!/usr/bin/env bash\n#{body}\n")
    File.chmod(0o755, path)
  end

  def run_ci(*args, **overrides)
    env = {
      "PATH" => "#{bin}:#{ENV.fetch("PATH")}",
      "FAKE_LOG" => log,
      "FAKE_ENV_COPIES" => env_copies,
      "FAKE_LABEL" => "abc123",
      "REVISION" => "abc123",
      "TIMEKEEPING_CI_DATABASE_URL" => database_url,
      "UP_ATTEMPTS" => "3"
    }.merge(fakes).merge(overrides)
    Open3.capture3(env, script, *args)
  end

  def docker_calls
    File.exist?(log) ? File.readlines(log, chomp: true) : []
  end

  def env_file(number)
    File.readlines(File.join(env_copies, number.to_s), chomp: true).to_h { |line| line.split("=", 2) }
  end

  describe "image" do
    it "builds Timekeeping's own Dockerfile from the repository root, with the commit as REVISION" do
      _out, err, status = run_ci("image")

      expect(status).to be_success, err
      expect(docker_calls.first).to eq(
        "build --file #{Rails.root}/services/timekeeping/Dockerfile --build-arg REVISION=abc123 --tag timekeeping:ci-abc123 #{Rails.root}"
      )
    end

    it "fails when the image does not record the revision it was built from" do
      _out, err, status = run_ci("image", "FAKE_LABEL" => "unknown")

      expect(status.exitstatus).to eq(1)
      expect(err).to include("the image records revision unknown, not abc123")
      expect(docker_calls.grep(/\Arun /)).to be_empty
    end

    it "fails when the build fails, starting nothing" do
      _out, _err, status = run_ci("image", "FAKE_BUILD_STATUS" => "1")

      expect(status).not_to be_success
      expect(docker_calls.grep(/\Arun /)).to be_empty
    end

    it "boots the web process, then checks its migration, then starts the relay's worker" do
      out, err, status = run_ci("image")

      expect(status).to be_success, err
      runs = docker_calls.grep(/\Arun /)
      expect(runs.size).to eq(2)
      expect(runs.first).to match(/\Arun --detach --name timekeeping-ci-web --network host --env-file \S+ timekeeping:ci-abc123\z/)
      expect(runs.last).to match(/\Arun --detach --name timekeeping-ci-relay --network host --env-file \S+ timekeeping:ci-abc123 bin\/rails solid_queue:start\z/)
      expect(File.read("#{log}.curl")).to include("http://127.0.0.1:3100/up")
      expect(docker_calls.grep(/\Aexec timekeeping-ci-web bin\/rails runner .*needs_migration\?/).size).to eq(1)
      expect(docker_calls.index { |call| call.start_with?("exec ") }).to be < docker_calls.index(runs.last)
      expect(out).to include("timekeeping-ci-web answers GET /up", "timekeeping-ci-relay is running")
    end

    it "gives both processes the database it is told and throwaway credentials, and removes them afterwards" do
      _out, err, status = run_ci("image")

      expect(status).to be_success, err
      web = env_file(1)
      expect(env_file(2)).to eq(web)
      expect(web).to include("DATABASE_URL" => database_url, "EXISTING_APP_URL" => "http://127.0.0.1:3000", "PORT" => "3100")
      expect(web.fetch("SECRET_KEY_BASE")).to match(/\A[0-9a-f]{128}\z/)
      expect(web.fetch("TIMEKEEPING_TOKEN_KEY")).to match(/\A[0-9a-f]{64}\z/)
      expect(File.readlines(File.join(env_copies, "paths"), chomp: true).uniq.map { |path| File.exist?(path) }).to eq([false])
    end

    it "makes new credentials on every run" do
      run_ci("image")
      first = env_file(1)
      FileUtils.rm_rf(Dir[File.join(env_copies, "*")])
      run_ci("image")

      expect(env_file(1).values_at("SECRET_KEY_BASE", "TIMEKEEPING_TOKEN_KEY"))
        .not_to eq(first.values_at("SECRET_KEY_BASE", "TIMEKEEPING_TOKEN_KEY"))
    end

    it "removes both containers when it ends" do
      run_ci("image")

      expect(docker_calls.last).to eq("rm --force timekeeping-ci-web timekeeping-ci-relay")
    end

    it "fails with the web process's logs when it exits before answering GET /up" do
      out, err, status = run_ci("image", "FAKE_CURL_STATUS" => "7", "FAKE_WEB_RUNNING" => "false")

      expect(status.exitstatus).to eq(1)
      expect(err).to include("the web process did not answer GET /up")
      expect(out).to include("logs of timekeeping-ci-web")
      expect(docker_calls.grep(/\Arun .*timekeeping-ci-relay/)).to be_empty
      expect(docker_calls.last).to eq("rm --force timekeeping-ci-web timekeeping-ci-relay")
    end

    it "stops waiting for GET /up after its attempts" do
      _out, err, status = run_ci("image", "FAKE_CURL_STATUS" => "7")

      expect(status.exitstatus).to eq(1)
      expect(err).to include("the web process did not answer GET /up")
      expect(File.readlines("#{log}.curl").size).to eq(3)
    end

    it "fails when the web process left the database unmigrated" do
      _out, err, status = run_ci("image", "FAKE_EXEC_STATUS" => "1")

      expect(status.exitstatus).to eq(1)
      expect(err).to include("the web process left the database unmigrated")
      expect(docker_calls.grep(/\Arun .*timekeeping-ci-relay/)).to be_empty
    end

    it "fails with the worker's logs when the relay's worker does not stay up" do
      out, err, status = run_ci("image", "FAKE_RELAY_RUNNING" => "false")

      expect(status.exitstatus).to eq(1)
      expect(err).to include("the relay's worker did not stay up")
      expect(out).to include("logs of timekeeping-ci-relay")
    end

    it "refuses to start without a database to boot on" do
      _out, err, status = run_ci("image", "TIMEKEEPING_CI_DATABASE_URL" => "")

      expect(status.exitstatus).to eq(1)
      expect(err).to include("set TIMEKEEPING_CI_DATABASE_URL")
      expect(docker_calls).to be_empty
    end
  end

  describe "tests" do
    it "runs Timekeeping's own suite from its own directory, after preparing its own test database" do
      body = File.read(script)[/^cmd_tests\(\) \{\n(.*?)^\}/m, 1]

      expect(body.lines.map(&:strip)).to eq(
        ['cd "${SERVICE_DIR}"', "RAILS_ENV=test bin/rails db:prepare", "RAILS_ENV=test bundle exec rspec"]
      )
      expect(Rails.root.join("services/timekeeping/config/database.yml").read).to include("database: timekeeping_test")
    end

    it "is the only runner of Timekeeping's suite: the existing application's runner leaves services/ out" do
      expect(Rails.root.join("bin/parallel_test").read).not_to include("services/")
    end
  end

  it "prints its usage, and refuses a step it does not have" do
    out, _err, status = run_ci("help")
    expect(status).to be_success
    expect(out).to include("services/timekeeping/bin/ci tests", "services/timekeeping/bin/ci image")

    _out, _err, status = run_ci("deploy")
    expect(status.exitstatus).to eq(1)
  end
end
