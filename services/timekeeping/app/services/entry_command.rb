# frozen_string_literal: true

# The steps the entry API's single-entry writes share
# (docs/architecture/timekeeping-soa.md §5.2, §6.2, §6.3, §9.4): the
# project the token names, the entry the write holds, a model refusal as the
# contract carries it, and an entry change saved with its audit and outbox
# rows. Each runs inside the call's EntryWrite transaction.
module EntryCommand
  # The facts of the project the token names (§6.1), when that is
  # `project_id` in the token's company; forbidden otherwise. The gateway
  # resolves the command's project before it signs the token, and never
  # sends another one.
  def self.project!(project_id, claims)
    project = claims.fetch("project")
    return project if project.present? && project.fetch("id") == project_id && project.fetch("company_id") == claims.fetch("company_id")

    raise Problem::Raised, Problem.new(
      slug: "forbidden", status: 403,
      detail: "project #{project_id} is not the token's project in company #{claims.fetch('company_id')}"
    )
  end

  # The kept entry `id` of the token's company, held FOR UPDATE until the
  # call's transaction ends, so an entry edit and a reservation change of
  # the same entry serialize (§9.4); once the caller is authorized on it
  # (EntryPolicy). Another company's entry, a discarded one or a missing one
  # is not-found.
  def self.held!(id, claims)
    entry = Entry.of_company(claims.fetch("company_id")).kept.lock.find_by(id:)
    raise Problem::Raised, Problem.new(slug: "not-found", status: 404, detail: "no entry #{id} in this company") unless entry

    entry.tap { EntryPolicy.authorize!(entry, claims) }
  end

  # validation-failed with the model's errors by attribute, in the model's
  # order, which the gateway answers as today's message (§5.1).
  def self.invalid(entry)
    Problem.new(
      slug: "validation-failed", status: 422, detail: entry.errors.full_messages.to_sentence,
      errors: entry.errors.to_hash.transform_keys(&:to_s)
    )
  end

  # Saves the change made to the held `entry`, already checked, as its next
  # version with its audit and outbox rows (EntryChange), and answers
  # [200, entry_response]. A change that changes nothing writes nothing, as
  # an update with no changes saves nothing today.
  def self.saved!(entry, claims)
    if entry.changed?
      entry.version += 1
      entry.save!(validate: false)
      EntryChange.record!(entry, action: "update", audited_changes: entry.audited_update_changes, claims:)
    end
    [200, { "entry" => entry.to_contract }]
  end
end
