# frozen_string_literal: true

# One page of the entry list (docs/architecture/timekeeping-soa.md §5.2,
# entry_api.json#/$defs/list_query): the entries of a scope, narrowed by every
# filter the query names, in pages of PAGE_SIZE. The cursor is the id the last
# page ended on, so a page is stable while entries are written; a null
# next_cursor is the last page.
module EntryList
  PAGE_SIZE = 500

  # The cursor is not one this list answered.
  class BadCursor < StandardError; end

  # Each filter the query may name narrows the scope; the contract has
  # already checked its shape.
  FILTERS = {
    "user_id" => ->(entries, user_id) { entries.where(user_id:) },
    "ids" => ->(entries, ids) { entries.where(id: ids) },
    "project_ids" => ->(entries, project_ids) { entries.where(project_id: project_ids) },
    "from" => ->(entries, from) { entries.where(work_date: Date.iso8601(from)..) },
    "to" => ->(entries, to) { entries.where(work_date: ..Date.iso8601(to)) },
    "cursor" => ->(entries, cursor) { entries.where(Entry.arel_table[:id].gt(last_id(cursor))) }
  }.freeze

  def self.page(scope, query)
    filtered = query.reduce(scope) { |entries, (name, value)| FILTERS.fetch(name).call(entries, value) }
    entries = filtered.includes(:reservations).order(:id).limit(PAGE_SIZE + 1).to_a
    page = entries.first(PAGE_SIZE)
    {
      "entries" => page.map(&:to_contract),
      "next_cursor" => (page.last.id.to_s if entries.size > PAGE_SIZE)
    }
  end

  def self.last_id(cursor)
    id = Integer(cursor, 10, exception: false)
    raise BadCursor, "cursor #{cursor.inspect} is not one this list answered" unless id&.positive?

    id
  end
  private_class_method :last_id
end
