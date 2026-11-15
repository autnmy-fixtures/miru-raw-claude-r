# frozen_string_literal: true

# The ownership states of docs/architecture/timekeeping-soa.md §10.1 and
# §10.5, as the handoff tool leaves the one record in each. The gates that
# read it (user hard delete, seed and demo-data builders) refuse in every
# state after the first handoff has begun.
module TimekeepingOwnershipStates
  BEFORE_FIRST_HANDOFF = { generation: 0, owner: "legacy", state: "open" }.freeze

  AFTER_HANDOFF_BEGUN = {
    "first handoff, admission closed" => { generation: 1, owner: "legacy", state: "closed" },
    "first handoff, frozen" => { generation: 1, owner: "legacy", state: "frozen" },
    "first handoff aborted" => { generation: 1, owner: "legacy", state: "open" },
    "cut over to Timekeeping" => { generation: 1, owner: "timekeeping", state: "open" },
    "rollback, frozen" => { generation: 2, owner: "timekeeping", state: "frozen" },
    "rolled back to the prepared application" => { generation: 2, owner: "monolith", state: "open" },
    "re-cut over to Timekeeping" => { generation: 3, owner: "timekeeping", state: "open" }
  }.freeze

  # Updates the row when a gateway write already inserted the initial one.
  def set_timekeeping_ownership!(attributes)
    Timekeeping::Ownership.current.tap { |ownership| ownership.update!(attributes) }
  end

  # Sets the prepared application's entry id sequence above every id in
  # timesheet_entries, as a rollback sets it (§10.3), so an entry the
  # `monolith` owner creates never takes the id of a projected one. It sets
  # it `margin` above, so ids a spec assigns itself stay below it.
  def advance_local_entry_ids!(margin: 10_000)
    connection = Timekeeping::Entry.connection
    connection.execute("SELECT setval(#{connection.quote(Timekeeping::Entry.sequence_name)}, #{TimesheetEntry.maximum(:id).to_i + margin})")
  end
end

RSpec.configure do |config|
  config.include TimekeepingOwnershipStates
end
