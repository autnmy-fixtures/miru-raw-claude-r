# frozen_string_literal: true

# The `timekeeping` owner of the gateway (docs/architecture/timekeeping-soa.md
# §3.1): entry writes go to Timekeeping's entry API (§5.2). So far it forwards
# the single-entry commands of W1 web and mobile, W3 CLI (and so W3a MCP) and
# W4 agent. The gateway refuses every other command under this owner.
#
# Each command becomes one request: the entry body the contract carries, the
# project it names, and the agent acting, if any. The interpreter adds the
# caller's claims (§6.1), the admitted generation and one Idempotency-Key, and
# answers the entry Timekeeping wrote as a read-only TimesheetEntry, so the
# controller renders it with today's code and public JSON does not change.
# Nothing is written to timesheet_entries here: it is the projection, with one
# writer (§3.2).
#
# The controller authorized the caller as today (§6.2). What the owner refuses
# is answered as today's public error JSON (§5.1): a stale generation or a
# moving owner is the retryable 503 of Ownership::Moving, anything else a
# Refused with the problem's status and today's message.
module Timekeeping::Gateway::Remote
  gateway = Timekeeping::Gateway

  # What one command asks of the entry API. `forward` makes the call.
  Request = Data.define(:project, :agent, :forward)

  # The legacy owner sets the command's project and user after the writer's
  # attributes on create, and the project before them on update; the bodies
  # keep that order.
  REQUESTS = {
    gateway::CreateEntry => ->(command) {
      entry = entry_attributes(command.attributes).compact
        .merge("project_id" => command.project.id, "user_id" => command.user.id)
      Request.new(project: command.project, agent: command.attributes[:agent], forward: ->(client, write) { client.create_entry(entry, write:) })
    },
    gateway::UpdateEntry => ->(command) {
      entry = { "project_id" => command.project.id }.merge(entry_attributes(command.attributes))
      Request.new(project: command.project, agent: nil, forward: ->(client, write) { client.update_entry(command.entry.id, entry, write:) })
    },
    gateway::DiscardEntry => ->(command) {
      Request.new(project: command.entry.project, agent: nil, forward: ->(client, write) { client.discard_entry(command.entry.id, write:) })
    }
  }.freeze

  # Problems that mean the generation moved under the command: a handoff is
  # running, so the command is retryable once it finishes (§9.3).
  MOVING = %w[stale-generation ownership-moving].freeze

  def self.handles?(command) = REQUESTS.key?(command.class)

  def self.call(command, ownership)
    request = REQUESTS.fetch(command.class).call(command)
    write = Timekeeping::EntryClient::Write.new(
      claims: claims(command, request), generation: ownership.generation, idempotency_key: SecureRandom.uuid
    )
    record(request.forward.call(Timekeeping::EntryClient.new, write))
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
  def self.claims(command, request)
    Timekeeping::UserToken.caller_claims(
      user: Current.user, company: request.project.client.company, writer: command.writer,
      project: request.project, agent: request.agent,
      request_id: Rails.event.context[:request_id] || SecureRandom.uuid
    )
  end
  private_class_method :claims

  # The owner's entry, for rendering only: never saved.
  def self.record(entry)
    TimesheetEntry.new(entry.except("company_id")).tap(&:readonly!)
  end
  private_class_method :record

  def self.refusal(problem)
    return Timekeeping::Ownership::Moving.new(I18n.t("timesheet_entry.ownership_moving")) if MOVING.include?(problem.type)

    Timekeeping::Gateway::Refused.new(status: problem.status, message: message(problem))
  end
  private_class_method :refusal

  # Today's message for a model error is its first full message; any other
  # problem says what it is.
  def self.message(problem)
    errors = ActiveModel::Errors.new(TimesheetEntry.new)
    problem.errors.each { |attribute, messages| messages.each { |text| errors.add(attribute, text) } }
    errors.full_messages.first || problem.detail.presence || problem.type.tr("-", " ").capitalize
  end
  private_class_method :message
end
