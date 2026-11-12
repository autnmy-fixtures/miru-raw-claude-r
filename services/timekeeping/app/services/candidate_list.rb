# frozen_string_literal: true

# Invoice candidate selection (docs/architecture/timekeeping-soa.md §3.3 rule
# 1, §5.2, entry_api.json#/$defs/candidates_query): the kept, unbilled entries
# of a scope that the shared rule finds selectable, narrowed by every filter
# the query names. It is a read that decides money, so the existing
# application asks it here instead of the projection, which may lag (§12.4
# "relay paused").
#
# It selects what GenerateInvoice::NewLineItemsService selects from the
# table today, with the one difference §7 makes: an entry is excluded by its
# reservations, as TimekeepingReservations.selectable? decides (a retained
# reservation does not count, L3, L4), instead of by the line items of kept
# invoices.
module CandidateList
  # The selection's own conditions, before any filter.
  UNBILLED = "unbilled"

  # Each filter the query may name; the contract has already checked its
  # shape. The client's kept projects arrive resolved as `project_ids` (the
  # gateway resolves them as the existing application does today), so
  # `client_id` narrows nothing more here: Timekeeping holds no catalogue.
  # The work-date range is the entry list's.
  FILTERS = EntryList::FILTERS.slice("from", "to").merge(
    "client_id" => ->(entries, _client_id) { entries },
    "project_ids" => ->(entries, project_ids) { entries.where(project_id: project_ids) },
    "user_ids" => ->(entries, user_ids) { entries.where(user_id: user_ids) },
    "exclude_ids" => ->(entries, exclude_ids) { entries.where.not(id: exclude_ids) },
    "search_term" => ->(entries, term) { NoteSearch.call(entries, term) }
  ).freeze

  # The candidates in today's order: by search rank when there is a search
  # term, then by id.
  def self.call(scope, query)
    candidates = query.reduce(scope.where(bill_status: UNBILLED)) { |entries, (name, value)| FILTERS.fetch(name).call(entries, value) }
    selectable = candidates.includes(:reservations).order(:id).select do |entry|
      TimekeepingReservations.selectable?(entry.id, entry.reservations.map(&:to_value))
    end
    { "entries" => selectable.map(&:to_contract) }
  end

  # The note search the existing application runs today:
  # TimesheetEntry.pg_search, a tsearch over `note` with the english
  # dictionary and prefix matching (app/models/timesheet_entry.rb), written
  # out as the SQL pg_search 2.3 builds for it, so a term selects the same
  # entries in the same rank order on either side. A blank term is no
  # search, as `search_term.present?` decides there.
  module NoteSearch
    DOCUMENT = "to_tsvector('english', coalesce((entries.note)::text, ''))"

    # Characters pg_search replaces with a space before quoting a word
    # (PgSearch::Features::TSearch::DISALLOWED_TSQUERY_CHARACTERS).
    DISALLOWED = /['?\\:‘’ʻʼ]/

    def self.call(entries, term)
      return entries if term.blank?

      query = "(#{tsquery(term)})"
      entries.where(Arel.sql("(#{DOCUMENT}) @@ #{query}"))
        .order(Arel.sql("ts_rank((#{DOCUMENT}), #{query}, 0) DESC"))
    end

    # Every word of the term, each a prefix, all of them required.
    def self.tsquery(term)
      term.split.map { |word| prefix_query(word.gsub(DISALLOWED, " ")) }.join(" && ")
    end
    private_class_method :tsquery

    def self.prefix_query(word)
      "to_tsquery('english', ''' ' || #{Entry.connection.quote(word)} || ' ''' || ':*')"
    end
    private_class_method :prefix_query
  end
end
