# frozen_string_literal: true

# W5's Harvest import batch (docs/architecture/timekeeping-soa.md §3.4, §5.2,
# §6.2): one mutating call in one transaction (EntryWrite), idempotent by
# import_id:batch_no, which the gateway sends as the call's Idempotency-Key.
#
# The existing application parsed the file and resolved each row's project
# and user; its token is the import job's system actor, carrying the facts
# of every project the rows name (`projects`, §6.1). Here, as today's
# importer loop does it (Timekeeping::Gateway::Legacy's ImportBatch):
#
# 1. every row's project is one the token names in its company, or the whole
#    batch is refused as forbidden, with nothing written: the gateway never
#    sends another;
# 2. each row is created under TimesheetEntry's create rules (Entry::CREATE),
#    with its project's facts. A row the rules reject is never inserted, so
#    it fails alone, answered by its index with the model's errors by
#    attribute, and the rest of the batch is kept, as today's savepoint per
#    row keeps it;
# 3. a billed row is created unbilled and then marked billed, because the
#    model refuses to create a billed entry (§1.3). Like today's create! then
#    update!, that is two versions, a create and an update audit row, and two
#    snapshots. The mark runs no rule: the update rules check the values the
#    create just accepted, and their one rule of their own, the edit lock,
#    cannot hold a new entry, which no reservation names.
module EntryImport
  # Answers [200, import_batch_response].
  def self.call(rows, claims)
    projects = EntryCommand.projects!(rows.map { |row| row.fetch("project_id") }, claims)
    imported = rows.map { |row| imported(row, projects.fetch(row.fetch("project_id")), claims) }
    created, failed = imported.each_with_index.partition { |entry, _index| entry.errors.empty? }

    [200, {
      "created_ids" => created.map { |entry, _index| entry.id },
      "failed_rows" => failed.map { |entry, index| { "index" => index, "errors" => entry.errors.to_hash.transform_keys(&:to_s) } }
    }]
  end

  # The row's entry: created, or with the errors that rejected it.
  def self.imported(row, project, claims)
    billed = row["bill_status"] == "billed"
    entry = Entry.new(row.merge("company_id" => claims.fetch("company_id"), "agent_id" => claims.dig("actor", "agent_id")))
    entry.bill_status = "unbilled" if billed
    entry.project_facts = project
    created = EntryCommand.created?(entry, claims)
    mark_billed!(entry, claims) if created && billed
    entry
  end
  private_class_method :imported

  def self.mark_billed!(entry, claims)
    entry.bill_status = "billed"
    EntryCommand.saved!(entry, claims)
  end
  private_class_method :mark_billed!
end
