# frozen_string_literal: true

# The one ownership record of docs/architecture/timekeeping-soa.md §10.1:
# which owner holds entries, under which generation, and whether admission is
# open. The handoff tool writes it; everything else only reads it.
#
# No row means no handoff has ever run here. The column defaults are the
# initial legacy state, so .current returns them unsaved instead of keeping a
# second copy of that state in code.
class Timekeeping::Ownership < ApplicationRecord
  SINGLETON_ID = 1
  INITIAL_GENERATION = 0

  # Raised by a seed or demo-data builder (W8) asked to write after a handoff
  # has begun (§10.1).
  class HandoffBegun < StandardError; end

  self.table_name = "timekeeping_ownerships"

  attribute :id, default: SINGLETON_ID

  enum :owner, { legacy: "legacy", timekeeping: "timekeeping", monolith: "monolith" }, prefix: true
  enum :state, { open: "open", closed: "closed", frozen: "frozen" }, prefix: true

  def self.current
    find_by(id: SINGLETON_ID) || new
  end

  def self.handoff_begun?
    current.handoff_begun?
  end

  # For the seed and demo-data builders: they write only in the initial legacy
  # state, by the same test as the user hard delete (§10.1).
  def self.ensure_initial!(builder)
    ownership = current
    return unless ownership.handoff_begun?

    raise HandoffBegun,
      "#{builder} refused: the Timekeeping handoff has begun (#{ownership.summary}). " \
      "Seed builders run only before the first handoff; reseeding needs a fresh demo reset."
  end

  # The test §10.1 names: a handoff has begun once admission is not open, or
  # once the generation has been raised above its value before the first
  # handoff. That covers a handoff in progress, either owner after it, an
  # aborted handoff and a rollback.
  def handoff_begun?
    !state_open? || generation > INITIAL_GENERATION
  end

  def summary
    "generation #{generation}, owner #{owner}, state #{state}"
  end
end
