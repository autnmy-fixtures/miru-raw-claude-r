# frozen_string_literal: true

# The `timekeeping` owner of the gateway (docs/architecture/timekeeping-soa.md
# §3.1): entry writes go to Timekeeping's entry API (§5.2). So far it forwards
# the single-entry commands of W1 web and mobile, W3 CLI (and so W3a MCP) and
# W4 agent, W2's bulk move and bulk discard, W5's import batches, and W6's
# agent detach. The gateway refuses every other command under this owner.
#
# Each command becomes one request: the tenant it runs in, the project it
# names, the agent acting, if any, and the writer. The interpreter adds the
# caller's claims (§6.1), the admitted generation and one Idempotency-Key,
# fresh for each command unless the request names its own;
# the request answers what Timekeeping wrote as read-only TimesheetEntry
# records, so the controller renders them with today's code and public JSON
# does not change. Nothing is written to timesheet_entries here: it is the
# projection, with one writer (§3.2).
#
# The controller authorized the caller as today (§6.2). What the owner refuses
# is answered as today's public error JSON (§5.1): a stale generation or a
# moving owner is the retryable 503 of Ownership::Moving, a locked entry a
# Locked, anything else a Refused with the problem's status and today's
# message.
module Timekeeping::Gateway::Remote
  gateway = Timekeeping::Gateway

  # What one command asks of the entry API. `forward` makes the call and
  # answers the command's result. The Idempotency-Key is shared by the
  # retries of this one command (§9.4); a command that is idempotent by its
  # own name, such as an import batch, names it.
  Request = Data.define(:company, :project, :agent, :writer, :forward, :idempotency_key) do
    def initialize(idempotency_key: SecureRandom.uuid, **) = super
  end

  # The legacy owner sets the command's project and user after the writer's
  # attributes on create, and the project before them on update; the bodies
  # keep that order. W2 is always the bulk writer (§6.1); a bulk move skips
  # what the owner's rules reject and still answers it (A9). W6 runs in the
  # agent's company, the only check Timekeeping makes for it (§6.2), and
  # answers the ids it detached; the agent row is deleted only after that
  # answer, by the destroy that sent it (§3.4). W5 runs in the importing
  # company as the import writer, names no one project (each row names its
  # own), and is idempotent by import_id:batch_no (§3.4); a billed row
  # travels billed, and the owner applies today's create-then-mark (§1.3).
  REQUESTS = {
    gateway::CreateEntry => ->(command) {
      entry = entry_attributes(command.attributes).compact
        .merge("project_id" => command.project.id, "user_id" => command.user.id)
      Request.new(
        company: command.project.client.company, project: command.project, agent: command.attributes[:agent], writer: command.writer,
        forward: ->(client, write) { record(client.create_entry(entry, write:)) }
      )
    },
    gateway::UpdateEntry => ->(command) {
      entry = { "project_id" => command.project.id }.merge(entry_attributes(command.attributes))
      Request.new(
        company: command.project.client.company, project: command.project, agent: nil, writer: command.writer,
        forward: ->(client, write) { record(client.update_entry(command.entry.id, entry, write:)) }
      )
    },
    gateway::DiscardEntry => ->(command) {
      Request.new(
        company: command.entry.project.client.company, project: command.entry.project, agent: nil, writer: command.writer,
        forward: ->(client, write) { record(client.discard_entry(command.entry.id, write:)) }
      )
    },
    gateway::BulkMove => ->(command) {
      Request.new(
        company: command.project.client.company, project: command.project, agent: nil, writer: "bulk",
        forward: ->(client, write) { client.bulk_move(command.entries.map(&:id), command.project.id, write:).map { |entry| record(entry) } }
      )
    },
    gateway::BulkDiscard => ->(command) {
      Request.new(
        company: command.company, project: nil, agent: nil, writer: "bulk",
        forward: ->(client, write) { client.bulk_discard(command.entries.map(&:id), write:) }
      )
    },
    gateway::DetachAgent => ->(command) {
      Request.new(
        company: command.agent.company, project: nil, agent: nil, writer: "agent_destroy",
        forward: ->(client, write) { client.detach_agent(command.agent.id, write:) }
      )
    },
    gateway::ImportBatch => ->(command) {
      rows = command.rows.map do |row|
        entry_attributes(row.except(:project, :user)).compact
          .merge("project_id" => row.fetch(:project).id, "user_id" => row.fetch(:user).id)
      end
      Request.new(
        company: command.company, project: nil, agent: nil, writer: "import",
        idempotency_key: "#{command.import_id}:#{command.batch_no}",
        forward: ->(client, write) { import_result(client.import_batch(command.import_id, command.batch_no, rows, write:)) }
      )
    }
  }.freeze

  # Problems that mean the generation moved under the command: a handoff is
  # running, so the command is retryable once it finishes (§9.3).
  MOVING = %w[stale-generation ownership-moving].freeze

  # The refusal each problem type is answered with; any other is a Refused.
  REFUSALS = { "entry-locked" => Timekeeping::Gateway::Locked }.freeze

  def self.handles?(command) = REQUESTS.key?(command.class)

  def self.call(command, ownership)
    request = REQUESTS.fetch(command.class).call(command)
    write = Timekeeping::EntryClient::Write.new(
      claims: claims(request), generation: ownership.generation, idempotency_key: request.idempotency_key
    )
    request.forward.call(Timekeeping::EntryClient.new, write)
  rescue Timekeeping::EntryClient::Invalid => error
    raise Timekeeping::Gateway::Refused.new(status: 422, message: error.errors.join("; "))
  rescue Timekeeping::EntryClient::Problem => problem
    raise refusal(problem)
  end

  # The writer's attributes as the contract carries them: cast by the model's
  # own attribute types, as today's save casts them, in JSON form. The agent
  # is not an attribute: it travels as the token's actor (§6.1).
  def self.entry_attributes(attributes)
    attributes.to_h.stringify_keys.except("agent")
      .to_h { |name, value| [name, TimesheetEntry.type_for_attribute(name).cast(value)] }
      .as_json
  end
  private_class_method :entry_attributes

  # Current.user is the caller the model's own checks read today (§2.2), so
  # its absence is the system actor of §6.1.
  def self.claims(request)
    Timekeeping::UserToken.caller_claims(
      user: Current.user, company: request.company, writer: request.writer,
      project: request.project, agent: request.agent,
      request_id: Rails.event.context[:request_id] || SecureRandom.uuid
    )
  end
  private_class_method :claims

  # What the owner wrote of one import batch, with each rejected row's model
  # errors as today's message for it: every full message, as one sentence.
  def self.import_result(answer)
    row_errors = answer.fetch("failed_rows").sort_by { |row| row.fetch("index") }
      .to_h { |row| [row.fetch("index"), full_messages(row.fetch("errors")).to_sentence] }
    Timekeeping::Gateway::ImportBatch::Result.new(created_ids: answer.fetch("created_ids"), row_errors:)
  end
  private_class_method :import_result

  # The owner's entry, for rendering only: never saved.
  def self.record(entry)
    TimesheetEntry.new(entry.except("company_id")).tap(&:readonly!)
  end
  private_class_method :record

  def self.refusal(problem)
    return Timekeeping::Ownership::Moving.new(I18n.t("timesheet_entry.ownership_moving")) if MOVING.include?(problem.type)

    REFUSALS.fetch(problem.type, Timekeeping::Gateway::Refused).new(status: problem.status, message: message(problem))
  end
  private_class_method :refusal

  # Today's message for a model error is its first full message; any other
  # problem says what it is.
  def self.message(problem)
    full_messages(problem.errors).first || problem.detail.presence || problem.type.tr("-", " ").capitalize
  end
  private_class_method :message

  # The model's full messages for errors the owner answered by attribute.
  def self.full_messages(errors_by_attribute)
    errors = ActiveModel::Errors.new(TimesheetEntry.new)
    errors_by_attribute.each { |attribute, messages| messages.each { |text| errors.add(attribute, text) } }
    errors.full_messages
  end
  private_class_method :full_messages
end
