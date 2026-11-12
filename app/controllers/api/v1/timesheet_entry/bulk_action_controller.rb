# frozen_string_literal: true

class Api::V1::TimesheetEntry::BulkActionController < Api::V1::ApplicationController
  skip_after_action :verify_authorized, only: [:update, :destroy]

  # The entries a request names are selected from their owner, under the
  # policy scope (A6): Timekeeping::EntryReads::Select applies
  # TimesheetEntryPolicy::Scope under every owner, so no Pundit scope is
  # resolved here. That way an entry the relay has not projected yet is found
  # and A9's lock is judged on the owner's state
  # (docs/architecture/timekeeping-soa.md §3.3 rule 1). The owner checks
  # A9's lock again in its write transaction (§6.2); its refusal is today's
  # locked answer.
  rescue_from Timekeeping::Gateway::Locked, with: :render_locked

  LOCKED_DEFAULTS = {
    "update" => "Only admins and owners can edit entries older than %{days} days",
    "destroy" => "Only admins and owners can delete entries older than %{days} days"
  }.freeze

  def update
    authorize TimesheetEntry, :bulk_update?

    ids = Array(params[:ids]).reject(&:blank?)
    return render json: { error: I18n.t("timesheet_entry.update.failure", default: "No entries selected") }, status: :unprocessable_entity if ids.empty?

    target_project = ProjectPolicy::Scope.new(current_user, current_company).resolve.find(params[:project_id])
    updated_entries = selected_entries(ids)
    return render json: { error: I18n.t("timesheet_entry.update.failure", default: "No entries found") }, status: :unprocessable_entity if updated_entries.empty?
    return render_locked if updated_entries.any? { |entry| entry_locked?(entry) }

    moved_entries = Timekeeping::Gateway.call(Timekeeping::Gateway::BulkMove.new(entries: updated_entries, project: target_project))
    entries = TimesheetEntriesPresenter.new(moved_entries).group_snippets_by_work_date
    render json: { notice: I18n.t("timesheet_entry.update.message"), entries: }, status: 200
  end

  def destroy
    authorize TimesheetEntry, :bulk_destroy?

    entries_to_discard = selected_entries(ids_params)
    return render_locked if entries_to_discard.any? { |entry| entry_locked?(entry) }

    discarded_entries = Timekeeping::Gateway.call(
      Timekeeping::Gateway::BulkDiscard.new(entries: entries_to_discard, company: current_company)
    )
    if discarded_entries.any?
      render json: { notice: I18n.t("timesheet_entry.destroy.message") }
    else
      render json: { error: I18n.t("timesheet_entry.destroy.failure", default: "Failed to delete timesheet entries") }, status: 422
    end
  end

  private

    def ids_params
      params.require(:source).require(:ids)
    end

    # The kept entries among `ids` the caller's policy scope admits (A6),
    # from the owner of the entries.
    def selected_entries(ids)
      Timekeeping::EntryReads.call(
        Timekeeping::EntryReads::Select.new(ids:, user: current_user, company: current_company, writer: "bulk")
      )
    end

    def privileged_user?
      current_user.has_role?(:admin, current_company) ||
        current_user.has_role?(:owner, current_company)
    end

    def render_locked(_refusal = nil)
      render json: {
        error: I18n.t(
          "timesheet_entry.#{action_name}.locked",
          days: current_company.timesheet_edit_days,
          default: LOCKED_DEFAULTS.fetch(action_name)
        )
      }, status: 403
    end

    def entry_locked?(entry)
      return true if entry.billed?
      return false if privileged_user?

      entry.work_date.present? && entry.work_date < current_company.timesheet_edit_days.days.ago.to_date
    end
end
