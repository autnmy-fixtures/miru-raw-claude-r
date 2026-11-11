# frozen_string_literal: true

class Api::V1::TimesheetEntryController < Api::V1::ApplicationController
  include DateRangeParamParsing

  skip_after_action :verify_authorized, only: [:index]
  after_action :verify_policy_scoped, only: [:index]

  def index
    policy_scope(TimesheetEntry)
    user = current_company.users.find(selected_user_id)
    data = TimeTrackingIndexService.new(
      current_user: current_user,
      user: user,
      company: current_company,
      from: parsed_date_param(:from) || 1.month.ago.beginning_of_month,
      to: parsed_date_param(:to) || 1.month.since.end_of_month,
      year: params[:year] || Date.today.year,
      writer:
    ).entries_payload

    render :index, locals: {
      entries: data[:entries],
      holiday_infos: data[:holiday_infos],
      leave_types: data[:leave_types],
      company: current_company
    }, status: 200
  end

  def create
    authorize TimesheetEntry
    timesheet_entry = Timekeeping::Gateway.call(
      Timekeeping::Gateway::CreateEntry.new(project: current_project, attributes: timesheet_entry_params, user: timesheet_entry_user, writer:)
    )
    render json: {
      notice: I18n.t("timesheet_entry.create.message"),
      entry: timesheet_entry.snippet
    }
  end

  def update
    authorize current_timesheet_entry
    timesheet_entry = Timekeeping::Gateway.call(
      Timekeeping::Gateway::UpdateEntry.new(entry: current_timesheet_entry, project: current_project, attributes: timesheet_entry_params, writer:)
    )
    render json: { notice: I18n.t("timesheet_entry.update.message"), entry: timesheet_entry.snippet },
      status: 200
  end

  def destroy
    authorize current_timesheet_entry
    Timekeeping::Gateway.call(Timekeeping::Gateway::DiscardEntry.new(entry: current_timesheet_entry, writer:))
    render json: { notice: I18n.t("timesheet_entry.destroy.message") }
  end

  private

    # This controller serves both W1 routes, and MCP's miru.time.list
    # reaches its index in-process (app/mcp/api_proxy.rb); the writer claim
    # tells them apart (docs/architecture/timekeeping-soa.md §6.1).
    def writer
      return "mcp" if request.env["miru.event_source"] == "mcp"

      request.path.start_with?("/api/v1/mobile/") ? "mobile" : "web"
    end

    def selected_user_id
      return current_user.id unless current_user.has_role?(:owner, current_company) || current_user.has_role?(:admin, current_company)

      params[:user_id] || current_user.id
    end

    def current_project
      @_current_project ||= current_company.projects.kept.find(params[:project_id])
    end

    # Read from the owner of the entries (§3.3 rule 1), so an entry just
    # written can be edited at once and is authorized on its current state.
    def current_timesheet_entry
      @_current_timesheet_entry ||= Timekeeping::EntryReads.call(
        Timekeeping::EntryReads::Find.new(id: params[:id], company: current_company, writer:)
      )
    end

    def timesheet_entry_user
      if current_user.has_role?(:owner, current_company) || current_user.has_role?(:admin, current_company)
        return current_company.users.find(params[:user_id] || current_user.id)
      end

      return current_user if params[:user_id].blank? || params[:user_id].to_i == current_user.id

      raise Pundit::NotAuthorizedError
    end

    def timesheet_entry_params
      params.require(:timesheet_entry).permit(:project_id, :duration, :work_date, :note, :bill_status)
    end
end
