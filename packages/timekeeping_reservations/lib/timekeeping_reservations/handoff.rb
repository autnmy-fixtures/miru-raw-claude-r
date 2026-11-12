# frozen_string_literal: true

module TimekeepingReservations
  # The handoff procedure's state machine over the ownership record
  # (docs/architecture/timekeeping-soa.md §10.1, §10.5). One record holds
  # (generation, owner, state), and §10.1 keeps "a copy in each database,
  # written by the handoff tool". The existing application's fence and
  # Timekeeping's both move their copy through these steps, so the two copies
  # cannot follow different rules:
  #
  #   close   step 1, open -> closed. Raises the generation.
  #   freeze  step 3, closed -> frozen.
  #   flip    step 7, frozen -> open under the incoming owner.
  #   abort   closed or frozen -> open under the outgoing owner. The raised
  #           generation stays, so commands admitted under the old one stay
  #           refused.
  #
  # Every step names the generation it expects to find, so a resumed handoff
  # re-runs exactly the step that did not commit, and a second tool, or a step
  # run twice, is refused and changes nothing.
  #
  # Pure: a fence locks its record, asks a step what to change, and persists
  # that. A record is anything with generation, owner and state.
  module Handoff
    # The step was asked of a record that is not where the caller expects the
    # handoff to be. Nothing changed.
    class OutOfStep < StandardError; end

    # Every owner has exactly one incoming owner (§3.1, §10.2): the first
    # cutover leaves legacy for good, rollback goes to the prepared
    # application, and re-cutover goes back to Timekeeping.
    SUCCESSORS = { "legacy" => "timekeeping", "timekeeping" => "monolith", "monolith" => "timekeeping" }.freeze

    # One row per step: the states it starts from, the state it leaves, and
    # what else it changes on the record.
    Step = Data.define(:name, :from, :to, :change) do
      # The attributes this step writes on `record`, or OutOfStep unless the
      # record is at `generation` in one of the step's `from` states.
      def apply(record, generation:)
        Handoff.ensure_in_step!(name, from, record, generation)
        change.call(record).merge(state: to)
      end
    end

    STEPS = [
      Step.new(name: :close, from: %w[open], to: "closed", change: ->(record) { { generation: record.generation + 1 } }),
      Step.new(name: :freeze, from: %w[closed], to: "frozen", change: ->(_) { {} }),
      Step.new(name: :flip, from: %w[frozen], to: "open", change: ->(record) { { owner: SUCCESSORS.fetch(record.owner) } }),
      Step.new(name: :abort, from: %w[closed frozen], to: "open", change: ->(_) { {} })
    ].to_h { |step| [step.name, step] }.freeze

    # Refuses with OutOfStep unless the record is at `generation` in one of the
    # `from` states. A step that changes no record (settle) checks its place
    # with it too.
    def self.ensure_in_step!(name, from, record, generation)
      return if record.generation == generation && from.include?(record.state)

      raise OutOfStep,
        "Timekeeping handoff: #{name} expects generation #{generation} in state #{from.join(' or ')}, " \
        "found #{summary(record)}; nothing changed"
    end

    def self.summary(record)
      "generation #{record.generation}, owner #{record.owner}, state #{record.state}"
    end
  end
end
