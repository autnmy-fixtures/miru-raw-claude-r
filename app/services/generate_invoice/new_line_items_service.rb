# frozen_string_literal: true

module GenerateInvoice
  class NewLineItemsService < ApplicationService
    # Where candidate selection reads (docs/architecture/timekeeping-soa.md
    # §3.3 rule 1): a read that decides money reads the owner of the entries.
    # Under `legacy` that is today's table. Under `timekeeping` it is the
    # owner's candidates, never the projection, which may lag behind it, so a
    # new entry can be invoiced at once (§12.4 "relay paused"). The `monolith`
    # owner arrives with its own entry store (§10.5); until then selection
    # refuses under it, as the gateway and the invoice boundary do.
    CANDIDATE_READS = { "legacy" => :table_candidates, "timekeeping" => :owner_candidates }.freeze

    # An owner's candidate with the catalogue records the suggestions read,
    # shaped as a loaded TimesheetEntry is.
    OwnerCandidate = Data.define(:id, :project_id, :user_id, :note, :work_date, :duration, :project, :user)

    attr_reader :client, :projects, :params
    attr_accessor :total_count

    def initialize(client, params)
      @client = client
      @params = params
      @projects = client.projects.includes(:project_members).kept
    end

    def process
      entries = new_line_item_entries
      {
        filter_options: {
          team_members: team_members_of_projects
        },
        new_line_item_entries: entries,
        total_new_line_items: total_count
      }
    end

    private

      # Sending team members list for filter dropdown options. The members of
      # the candidates are included too: under an owner, a candidate may not
      # be projected yet.
      def team_members_of_projects
        @team_members_of_projects ||= User.where(
          id: TimesheetEntry.kept.where(project_id: @projects).pluck(:user_id) | candidates.map(&:user_id)
        )
      end

      # merging selected_entries from params with ids already present in other invoice line items
      def filtered_ids
        discarded_invoice_ids = Invoice.kept.pluck(:id)
        direct_entry_ids = InvoiceLineItem.joins(:timesheet_entry)
          .where(invoice_id: discarded_invoice_ids)
          .where(timesheet_entries: { bill_status: "unbilled", discarded_at: nil })
          .pluck(:timesheet_entry_id)
        linked_entry_ids = InvoiceLineItemTimeEntry
          .joins(:timesheet_entry, :invoice_line_item)
          .where(invoice_line_items: { invoice_id: discarded_invoice_ids })
          .where(timesheet_entries: { bill_status: "unbilled", discarded_at: nil })
          .pluck(:timesheet_entry_id)

        @filtered_ids ||= params[:selected_entries].to_a | direct_entry_ids | linked_entry_ids
      end

      def where_clause
        filters = TimeEntries::Filters.process(params)
        filters[:project_id] = selected_project_ids(filters) if filters[:project_id]

        {
          project_id: @projects.ids,
          id: { not: filtered_ids },
          bill_status: "unbilled",
          discarded_at: nil
        }.merge(filters)
      end

      def search_term
        @_search_term = params[:search_term].presence || "*"
      end

      # The client's kept projects, narrowed by the client filter when given.
      def selected_project_ids(filters)
        allowed_project_ids = @projects.ids
        filters.key?(:project_id) ? Array(filters[:project_id]) & allowed_project_ids : allowed_project_ids
      end

      def new_line_item_entries
        timesheet_entries = candidates

        @total_count = timesheet_entries.count
        format_timesheet_entries(timesheet_entries)
      end

      def candidates
        @candidates ||= send(CANDIDATE_READS.fetch(owner) {
          raise Timekeeping::Gateway::OwnerUnavailable, "invoice candidate selection: owner #{owner} has no entry store yet"
        })
      end

      def owner
        @owner ||= Timekeeping::Ownership.current.owner
      end

      def table_candidates
        search_timesheet_entries(search_term, where_clause)
      end

      # The same selection, asked of the owner (§5.2 candidates). The owner
      # excludes every entry an invoice holds by its reservations, so only
      # the entries the caller already selected are excluded here; kept and
      # unbilled are the contract's own conditions.
      def owner_candidates
        filters = TimeEntries::Filters.process(params)
        entries = Timekeeping::EntryClient.new.candidates(
          company: client.company,
          client_id: client.id,
          project_ids: selected_project_ids(filters),
          user_ids: filters.key?(:user_id) ? row_ids(filters[:user_id]) : nil,
          exclude_ids: row_ids(params[:selected_entries]),
          work_dates: filters[:work_date]&.then { |dates| dates.begin.to_date..dates.end.to_date },
          search_term: (search_term unless search_term == "*")
        )
        with_catalogue(entries)
      end

      # Posted ids as decimal integers; one that can name no row is dropped.
      def row_ids(ids)
        Array(ids).filter_map { |id| Integer(id.to_s, 10, exception: false) }.select(&:positive?)
      end

      def with_catalogue(entries)
        projects = @projects.index_by(&:id)
        users = User.where(id: entries.map(&:user_id)).index_by(&:id)
        entries.map do |entry|
          OwnerCandidate.new(
            **entry.to_h.slice(*OwnerCandidate.members),
            project: projects.fetch(entry.project_id), user: users.fetch(entry.user_id)
          )
        end
      end

      def search_timesheet_entries(search_term, where_clause)
        entries = TimesheetEntry.includes(:user, project: :client)

        where_clause.each do |key, value|
          entries = if value.is_a?(Hash) && value.key?(:not)
            entries.where.not(key => value[:not])
          else
            entries.where(key => value)
          end
        end

        if search_term.present? && search_term != "*"
          entries = entries.pg_search(search_term) if entries.respond_to?(:pg_search)
        end

        entries
      end

      def format_timesheet_entries(timesheet_entries)
        user_project_rates = ProjectMembersPresenter.new(projects).project_to_member_hourly_rate

        return format_project_aggregates(timesheet_entries, user_project_rates) if group_by_project?

        timesheet_entries.map do |timesheet_entry|
          rate = user_project_rates[timesheet_entry.project_id][timesheet_entry.user_id]

          {
            selection_id: "timesheet-entry-#{timesheet_entry.id}",
            timesheet_entry_id: timesheet_entry.id,
            linked_timesheet_entry_ids: [],
            user_id: timesheet_entry.user_id,
            project_id: timesheet_entry.project_id,
            project_name: timesheet_entry.project.name,
            first_name: timesheet_entry.user.first_name,
            last_name: timesheet_entry.user.last_name,
            description: timesheet_entry.note,
            date: timesheet_entry.work_date,
            quantity: timesheet_entry.duration,
            rate:
          }
        end
      end

      def group_by_project?
        ActiveModel::Type::Boolean.new.cast(params[:group_by_project])
      end

      def format_project_aggregates(timesheet_entries, user_project_rates)
        timesheet_entries
          .group_by { |entry| [entry.project_id, entry.user_id, user_project_rates[entry.project_id][entry.user_id]] }
          .map do |(project_id, user_id, rate), entries|
            first_entry = entries.first
            work_dates = entries.map(&:work_date)

            {
              selection_id: "project-aggregate-#{project_id}-#{user_id}-#{formatted_rate(rate)}",
              timesheet_entry_id: nil,
              linked_timesheet_entry_ids: entries.map(&:id),
              user_id:,
              project_id:,
              project_name: first_entry.project.name,
              first_name: nil,
              last_name: nil,
              name: first_entry.project.name,
              description: "#{first_entry.user.full_name} - #{entries.size} entries",
              date: work_dates.min,
              date_range: [work_dates.min, work_dates.max].uniq.join(" - "),
              quantity: entries.sum(&:duration),
              rate:,
              entry_count: entries.size
            }
          end
      end

      def formatted_rate(rate)
        return rate.to_s("F") if rate.is_a?(BigDecimal)

        rate.to_s
      end
  end
end
