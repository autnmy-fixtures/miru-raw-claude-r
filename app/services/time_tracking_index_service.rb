# frozen_string_literal: true

class TimeTrackingIndexService
  include EmployeeFetchingConcern

  attr_reader :current_user, :user, :current_company, :entries, :from, :to, :year, :writer
  attr_accessor :clients, :projects, :employees

  # `writer` names the route reading, for the owner's claims
  # (docs/architecture/timekeeping-soa.md §6.1).
  def initialize(current_user:, user:, company:, from:, to:, year:, writer: "web")
    @current_user = current_user
    @writer = writer
    @user = user
    @current_company = company
    @from = from
    @to = to
    @year = year
    @entries = {}
  end

  def process
    setup_data

    {
      clients:,
      projects:,
      entries: format_entries,
      employees:,
      leave_types:,
      holiday_infos:
    }
  end

  def entries_payload
    {
      entries: format_entries,
      leave_types:,
      holiday_infos:
    }
  end

  private

    def setup_data
      set_clients
      set_projects
      set_employees
    end

    def format_entries
      formatted_timesheet_entries
      group_timeoff_entries_by_leave_date
      entries
    end

    # Read from the owner of the entries (§3.3 rule 1), so an entry just
    # written is listed before the projection holds it.
    def fetch_timesheet_entries
      Timekeeping::EntryReads.call(Timekeeping::EntryReads::List.new(user:, company: current_company, from:, to:, writer:))
    end

    def formatted_timesheet_entries
      timesheet_entries = fetch_timesheet_entries
      @entries = TimesheetEntriesPresenter.new(timesheet_entries).group_snippets_by_work_date
    end

    def set_clients
      @clients = ClientPolicy::Scope.new(current_user, current_company).resolve.includes(:addresses)
    end

    def set_projects
      user_projects_by_client = ProjectPolicy::Scope.new(current_user, current_company)
        .resolve
        .kept
        .group_by(&:client_id)

      @projects = clients.each_with_object({}) do |client, grouped_projects|
        grouped_projects[client.name] = user_projects_by_client[client.id] || []
      end
    end

    def timeoff_entries
      @_timeoff_entries ||= TimeoffEntry.from_workspace(current_company.id)
        .where(user_id: user.id)
        .during(from, to)
        .distinct
    end

    def group_timeoff_entries_by_leave_date
      timeoff_entries.each do |entry|
        @entries[entry.leave_date] ||= []
        @entries[entry.leave_date] << entry
      end
    end

    def leave_types
      leave = current_company.leaves.find_by(year:)
      return [] unless leave

      regular_leave_types = leave.leave_types&.kept || []
      user_custom_leaves = leave.custom_leaves.joins(:custom_leave_users)
        .where(custom_leave_users: { user_id: user.id })

      regular_leave_types + user_custom_leaves
    end

    def holiday_infos
      holiday = current_company.holidays.find_by(year:)
      all_holidays = holiday&.holiday_infos&.kept
      return [] if holiday.blank? || all_holidays.blank?

      holiday.enable_optional_holidays ? all_holidays : all_holidays.national
    end
end
