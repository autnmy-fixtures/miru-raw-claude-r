# frozen_string_literal: true

# The reservation rule of docs/architecture/timekeeping-soa.md §7: an entry has
# at most one reservation by a kept invoice, provisional or committed, changed
# only through prepare, commit and abort. One decision table (§7.2), shared by
# Timekeeping, the write gateway and the prepared rollback target (§10.5).
# Nobody re-implements it.
#
# Everything here is pure. A provider loads, under SELECT ... FOR UPDATE (§9.4),
# the operation's entries and every reservation those entries and the invoice
# hold, calls prepare, commit or abort, and persists the reservations it gets
# back. Receipts, generations and the one-unresolved-operation rule are the
# protocol's (§5.3), not the table's.
#
# The handoff's state machine over the ownership record, which both copies of
# that record move through, is TimekeepingReservations::Handoff.
module TimekeepingReservations
  KINDS = %i[save discard destroy].freeze
  INVOICE_STATES = %i[draft non_draft].freeze

  # A commit whose operation never prepared an entry it adds. The provider
  # answers an unprepared operation before it reaches the table (§5.3).
  class ProtocolError < StandardError; end

  # The operation as prepare received it. `entry_ids` is the desired set:
  # every entry the invoice's remaining direct and grouped lines reference.
  # Empty for discard and destroy, which act on every entry the invoice holds.
  Operation = Data.define(:invoice_id, :operation_id, :company_id, :kind, :invoice_state, :entry_ids) do
    def initialize(kind:, invoice_state:, entry_ids: [], **rest)
      raise ArgumentError, "unknown operation kind #{kind.inspect}" unless KINDS.include?(kind)
      raise ArgumentError, "unknown invoice state #{invoice_state.inspect}" unless INVOICE_STATES.include?(invoice_state)

      super(kind:, invoice_state:, entry_ids: entry_ids.uniq.freeze, **rest)
    end
  end

  # Identified by (entry, invoice) once committed. A provisional one belongs
  # to the operation that prepared it and carries the disposition it commits to.
  Reservation = Data.define(:entry_id, :invoice_id, :company_id, :operation_id, :state, :disposition, :edit_lock) do
    def provisional? = state == :provisional
    def active? = state == :committed && disposition == :active
    def retained? = state == :committed && disposition == :retained
    def held_by?(invoice_id) = active? && self.invoice_id == invoice_id
    def of?(operation) = provisional? && operation_id == operation.operation_id
  end

  # What prepare knows of an entry it is asked to add: that it exists, and its tenant.
  Entry = Data.define(:id, :company_id)

  Refusal = Data.define(:entry_id, :reason)
  Prepared = Data.define(:reservations)
  Refused = Data.define(:refusals)

  # How an operation relates each entry to the invoice, from the desired set
  # and the entries the invoice holds an active reservation on (§7.2, last
  # paragraph: an entry is removed only when no remaining line references it).
  RELATIONS = {
    save: ->(desired, held) { { added: desired - held, kept: desired & held, removed: held - desired } },
    discard: ->(_desired, held) { { all: held } },
    destroy: ->(_desired, held) { { all: held } }
  }.freeze

  # §7.2, one entry per row: [operation, invoice state, entry] => effect at
  # prepare and at commit. The two "any" rows are REFUSALS and :activate.
  TABLE = {
    [:save, :draft, :added] => { prepare: :reserve_locked, commit: :activate },     # L1
    [:save, :draft, :kept] => { prepare: :none, commit: :lock },                    # L1: a draft save re-locks all
    [:save, :draft, :removed] => { prepare: :none, commit: :release },              # L4; F3
    [:save, :non_draft, :added] => { prepare: :reserve_unlocked, commit: :activate }, # L1: not locked after draft
    [:save, :non_draft, :kept] => { prepare: :none, commit: :none },
    [:save, :non_draft, :removed] => { prepare: :none, commit: :retain },           # L4
    [:discard, :draft, :all] => { prepare: :none, commit: :release },               # F2 (today: stays locked, K2)
    [:discard, :non_draft, :all] => { prepare: :none, commit: :retain },            # L3
    [:destroy, :draft, :all] => { prepare: :none, commit: :release },               # K7; F3 for linked entries
    [:destroy, :non_draft, :all] => { prepare: :none, commit: :retain }             # K7: owner carried by the reservation
  }.freeze

  # Each effect maps one entry's reservations to its new reservations.
  EFFECTS = {
    none: ->(reservations, _entry_id, _operation) { reservations },
    reserve_locked: ->(reservations, entry_id, operation) { reservations | [provisional(entry_id, operation, edit_lock: true)] },
    reserve_unlocked: ->(reservations, entry_id, operation) { reservations | [provisional(entry_id, operation, edit_lock: false)] },
    activate: ->(reservations, entry_id, operation) { succeed(reservations, entry_id, operation) },
    lock: ->(reservations, _entry_id, operation) { update_held(reservations, operation, edit_lock: true) },
    release: ->(reservations, _entry_id, operation) { reservations.reject { |held| held.held_by?(operation.invoice_id) } },
    retain: ->(reservations, _entry_id, operation) { update_held(reservations, operation, disposition: :retained) }
  }.freeze

  # Why prepare refuses an entry it is asked to add; the first that holds wins.
  # The reasons are the contract's (reservation-refused, common.json).
  REFUSALS = {
    not_found: ->(entry, _operation, _reservations) { entry.nil? },                     # §5.3: authoritative for existence
    wrong_company: ->(entry, operation, _reservations) { entry.company_id != operation.company_id }, # L8
    on_other_invoice: ->(_entry, operation, reservations) {                              # F1
      reservations.any? { |held| held.active? || (held.provisional? && !held.of?(operation)) }
    }
  }.freeze

  class << self
    # Reserves the entries the operation adds, provisionally, or refuses.
    # `entries` maps each id the operation asks for to its Entry, when it exists.
    def prepare(operation, entries:, reservations:)
      added = relations(operation, reservations).fetch(:added, [])
      refusals = added.filter_map { |entry_id| refusal(entry_id, entries[entry_id], operation, of_entry(reservations, entry_id)) }
      return Refused.new(refusals:) if refusals.any?

      Prepared.new(reservations: apply(:prepare, operation, reservations))
    end

    # Makes the desired set the reservation set and applies the table's
    # effect to every entry the operation keeps, removes or acts on.
    def commit(operation, reservations:)
      apply(:commit, operation, reservations)
    end

    # Drops only this operation's provisional reservations (§5.3).
    def abort(operation, reservations:)
      reservations.reject { |reservation| reservation.of?(operation) }
    end

    # The projection's `locked`: true exactly when the entry holds a
    # reservation with edit_lock (§7.1), provisional and retained included.
    def locked?(entry_id, reservations)
      of_entry(reservations, entry_id).any?(&:edit_lock)
    end

    # Candidate selection: a retained reservation does not count (§7.1, L3, L4).
    def selectable?(entry_id, reservations)
      of_entry(reservations, entry_id).none? { |reservation| reservation.active? || reservation.provisional? }
    end

    private

      def relations(operation, reservations)
        held = reservations.filter_map { |reservation| reservation.entry_id if reservation.held_by?(operation.invoice_id) }.uniq
        RELATIONS.fetch(operation.kind).call(operation.entry_ids, held)
      end

      # Relations are read once, from the reservations as they were before the
      # operation, then each entry's effect is applied to its own reservations.
      def apply(phase, operation, reservations)
        relations(operation, reservations).reduce(reservations) do |result, (relation, entry_ids)|
          effect = EFFECTS.fetch(TABLE.fetch([operation.kind, operation.invoice_state, relation]).fetch(phase))
          entry_ids.reduce(result) do |current, entry_id|
            ours, others = current.partition { |reservation| reservation.entry_id == entry_id }
            others + effect.call(ours, entry_id, operation)
          end
        end
      end

      def refusal(entry_id, entry, operation, reservations)
        reason, = REFUSALS.find { |_reason, refuses| refuses.call(entry, operation, reservations) }
        reason && Refusal.new(entry_id:, reason:)
      end

      def of_entry(reservations, entry_id)
        reservations.select { |reservation| reservation.entry_id == entry_id }
      end

      def provisional(entry_id, operation, edit_lock:)
        Reservation.new(
          entry_id:, invoice_id: operation.invoice_id, company_id: operation.company_id,
          operation_id: operation.operation_id, state: :provisional, disposition: :active, edit_lock:
        )
      end

      # The operation's provisional reservation becomes the committed one and
      # succeeds every retained reservation the entry held (§7.1).
      def succeed(reservations, entry_id, operation)
        prepared = reservations.find { |reservation| reservation.of?(operation) }
        raise ProtocolError, "operation #{operation.operation_id} did not prepare entry #{entry_id}" unless prepared

        reservations.reject { |reservation| reservation.retained? || reservation == prepared } +
          [prepared.with(state: :committed, operation_id: nil)]
      end

      def update_held(reservations, operation, **changes)
        reservations.map { |reservation| reservation.held_by?(operation.invoice_id) ? reservation.with(**changes) : reservation }
      end
  end
end

require_relative "timekeeping_reservations/handoff"
