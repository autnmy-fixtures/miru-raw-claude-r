# frozen_string_literal: true

# What the local demo's drivers that run the three handoffs themselves share:
# the end-to-end journey (Timekeeping::Journey, docs/architecture/
# timekeeping-soa.md §13 item 1) and the alternating-writers proof
# (Timekeeping::AlternatingWriters, §12.4). Each starts from a freshly seeded
# demo, writes a stage under every owner, and runs each handoff with its own
# runner between stages, with the financial snapshot (§13 item 2) taken just
# before and just after it.
#
# A class that includes it also includes Timekeeping::PublicApi, and sets
# @handoff: called with a STAGES handoff name, it runs that handoff to its
# end or raises.
module Timekeeping::DemoHandoffs
  # The stages, each under the owner the handoff before it left, and the
  # handoff that ends each one.
  STAGES = [
    { owner: "legacy", handoff: "first_cutover" },
    { owner: "timekeeping", handoff: "rollback" },
    { owner: "monolith", handoff: "recutover" },
    { owner: "timekeeping", handoff: nil }
  ].freeze

  private

    def ensure_fresh!
      ownership = Timekeeping::Ownership.current
      return unless ownership.handoff_begun?

      fail! "the #{log_prefix} starts from a freshly seeded demo, before any handoff; ownership is #{ownership.summary}"
    end

    def ensure_owner!(owner)
      ownership = Timekeeping::Ownership.current
      return if ownership.owner == owner && ownership.state_open?

      fail! "expected the #{owner} owner with admission open, found #{ownership.summary}"
    end

    def hand_off(name)
      say "handoff: #{name}"
      before = Timekeeping::FinancialSnapshot.process
      begin
        @handoff.call(name)
      rescue SystemExit, StandardError => error
        fail! "the #{name} handoff stopped: #{error.message}"
      end
      differences = Timekeeping::FinancialSnapshot.diff(before, Timekeeping::FinancialSnapshot.process)
      fail! "the #{name} handoff changed money: #{differences.first(10).map(&:to_h)}" if differences.any?

      say "handoff: #{name} done, financial snapshot identical (#{before.sum { |_table, rows| rows.size }} rows), " \
          "ownership #{Timekeeping::Ownership.current.summary}"
    end
end
