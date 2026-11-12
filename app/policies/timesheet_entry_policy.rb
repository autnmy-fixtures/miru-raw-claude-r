# frozen_string_literal: true

class TimesheetEntryPolicy < ApplicationPolicy
  def show?
    user_owner_role? || user_admin_role? || user_employee_role?
  end

  def index?
    show?
  end

  def create?
    user_owner_role? || user_admin_role? || user_employee_role?
  end

  def bulk_update?
    create?
  end

  def bulk_destroy?
    create?
  end

  def update?
    return false if record.billed?
    return false if stale_entry_for_non_privileged?
    return true if privileged_role_for_record?

    record.user_id == user.id
  end

  def destroy?
    update?
  end

  private

    def privileged_role_for_record?
      user.has_role?(:owner, record.project.client.company) ||
        user.has_role?(:admin, record.project.client.company)
    end

    def stale_entry_for_standard_user?
      return false if record.work_date.blank?

      edit_days = record.project.client.company.timesheet_edit_days
      record.work_date < edit_days.days.ago.to_date
    end

    def stale_entry_for_non_privileged?
      stale_entry_for_standard_user? && !privileged_role_for_record?
    end

    class Scope < ApplicationPolicy
      attr_reader :user, :scope

      def initialize(user, scope)
        @user = user
        @scope = scope
      end

      def resolve
        if own_entries_only?
          user.timesheet_entries.kept.in_workspace(user.current_workspace)
        else
          user.current_workspace.timesheet_entries.kept
        end
      end

      # A6: owner and admin see every kept entry of the workspace, everyone
      # else their own. Timekeeping::EntryReads applies the same rule to the
      # owner of the entries.
      def own_entries_only?
        !has_owner_or_admin_role?
      end
    end
end
