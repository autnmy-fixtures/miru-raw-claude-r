# frozen_string_literal: true

# The prepared application's entry store (docs/architecture/timekeeping-soa.md
# §3.1, §10.5): the authoritative entries the `monolith` owner holds, which
# Timekeeping::LocalReservations takes as its `entries`. It is inactive: no
# owner routes to it until the `monolith` owner is built.
#
# `lock(ids)` takes the entry rows SELECT ... FOR UPDATE in id order (§9.4),
# so reservation changes serialize with entry edits and with each other, as
# Timekeeping's ReservationProtocol locks its entries. It answers
# { id => TimekeepingReservations::Entry } for the ids that exist, discarded
# ones included: existence and company are what the rule decides on (L8).
class Timekeeping::LocalEntries
  def lock(ids)
    Timekeeping::Entry.where(id: ids).order(:id).lock.pluck(:id, :company_id)
      .to_h { |id, company_id| [id, TimekeepingReservations::Entry.new(id:, company_id:)] }
  end
end
