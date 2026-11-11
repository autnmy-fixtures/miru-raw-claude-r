# frozen_string_literal: true

module ErrorHandler
  extend ActiveSupport::Concern

  included do
    rescue_from ActionController::RoutingError, ActiveRecord::RecordNotFound, with: :handle_not_found_error
    rescue_from Pundit::NotAuthorizedError, with: :user_not_authorized
    rescue_from Discard::RecordNotDiscarded, with: :record_not_discarded
    rescue_from ActiveRecord::RecordInvalid, with: :record_invalid
    rescue_from Pagy::VariableError, with: :invalid_param_value
    rescue_from Timekeeping::Ownership::Moving, with: :ownership_moving
    rescue_from Timekeeping::InvoiceBoundary::Failed, with: :invoice_reservation_failed
    rescue_from Timekeeping::InvoiceOperation::Busy, with: :invoice_operation_busy
    rescue_from Timekeeping::EntryClient::Unavailable, with: :timekeeping_unavailable
  end

  # How an invoice write that the reservation boundary failed is answered
  # (docs/architecture/timekeeping-soa.md §9.3): a refused prepare (F1, L8) is
  # today's 422 shape with the refused entry named; a write that collided
  # with another operation of the same invoice is a retryable 409; any other
  # retryable failure, Timekeeping down included, is a retryable 503, and any
  # other failure a 422.
  INVOICE_RESERVATION_STATUS = {
    reservation_refused: 422,
    operation_unresolved: 409,
    desired_set_changed: 409,
    unreconciled: 409
  }.freeze
  INVOICE_RESERVATION_MESSAGE = { 409 => "busy", 503 => "unavailable" }.freeze

  private

    def handle_not_found_error(exception)
      message = exception.message || I18n.t("errors.not_found")

      respond_to do |format|
        format.json { render json: { errors: message }, status: 404 }
        format.html { render file: "public/404.html", status: 404, layout: false, alert: message }
      end
    end

    def user_not_authorized(exception)
      redirect_path = root_path
      policy = exception.policy
      policy_name = policy.class.to_s.underscore
      error_key = policy.try(:error_message_key) || exception.query

      message = I18n.t("#{policy_name}.#{error_key}", scope: "pundit", default: :default)
      message = I18n.t("pundit.different_workspace") if policy.try(:error_message_key) == :different_workspace

      respond_to do |format|
        format.html do
          flash.now[:alert] = message
          redirect_to redirect_path
        end
        format.json { render json: { errors: message }, status: 403 }
        format.any(:pdf, :csv) { render json: { errors: message }, status: 403 }
      end
    end

    def record_not_discarded(exception)
      message = exception.message

      respond_to do |format|
        format.json { render json: { errors: message }, status: 500 }
        format.html { render file: "public/500.html", status: 500, layout: false, alert: message }
      end
    end

    def record_invalid(exception)
      message = exception.message

      respond_to do |format|
        format.json { render json: { errors: exception.record.errors.full_messages.first }, status: 422 }
        format.html { render file: "public/422.html", status: 422, layout: false, alert: message }
      end
    end

    # A Timekeeping handoff closed admission while this write was made
    # (docs/architecture/timekeeping-soa.md §10.1). Nothing was written, and
    # the same request succeeds once the handoff finishes, so it is a
    # retryable 503 rather than a failure of the request itself.
    def ownership_moving(exception)
      message = exception.message

      respond_to do |format|
        format.json { render json: { errors: message }, status: 503 }
        format.html { render plain: message, status: 503 }
      end
    end

    def invoice_reservation_failed(exception)
      status = INVOICE_RESERVATION_STATUS.fetch(exception.reason) { exception.retryable ? 503 : 422 }
      refusal = exception.refused.first
      message =
        if refusal
          I18n.t(refusal.reason, scope: "invoices.reservation.refused", entry_id: refusal.entry_id)
        else
          I18n.t(INVOICE_RESERVATION_MESSAGE.fetch(status, "failed"), scope: "invoices.reservation")
        end

      render json: { errors: message }, status:
    end

    # Another operation of the same invoice is still pending (§9.1).
    def invoice_operation_busy(_exception)
      render json: { errors: I18n.t("invoices.reservation.busy") }, status: 409
    end

    # A read that decides money could not reach the owner of the entries
    # (docs/architecture/timekeeping-soa.md §3.3 rule 1). Nothing was read,
    # and the same request may succeed later.
    def timekeeping_unavailable(_exception)
      render json: { errors: I18n.t("timesheet_entry.unavailable") }, status: 503
    end

    def invalid_param_value(exception)
      message = exception.message

      respond_to do |format|
        format.json { render json: { errors: message }, status: 400 }
        format.html { render file: "public/400.html", status: 400, layout: false, alert: message }
      end
    end
end
