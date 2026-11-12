# frozen_string_literal: true

# One time entry, as Timekeeping owns it (docs/architecture/timekeeping-soa.md
# §3.2): the existing application's timesheet_entries row, with the tenant it
# belongs to (§6.3) and its version (§3.2).
#
# A writer's rules (§2.1, §6.2) run only in the writer's validation context,
# CREATE: a row a checkpoint loads (§10.5 step 4) or a spec writes directly is
# copied, never normalized or re-validated (§8 item 1).
class Entry < ApplicationRecord
  # The entry's fields as common.json#/$defs/entry_fields names them, in
  # order, apart from the derived `locked`.
  FIELDS = %w[
    project_id user_id agent_id duration work_date note bill_status review_status
    source source_metadata proof_url proof_metadata external_run_id external_session_id
    discarded_at created_at updated_at
  ].freeze

  # How each field that is not already JSON is carried (§5.1): dates as ISO
  # 8601, timestamps in UTC to the microsecond. `duration` is the stored
  # float, which JSON writes in Ruby's shortest round-trip form.
  FORMATS = {
    "work_date" => :iso8601.to_proc,
    "discarded_at" => ->(time) { time&.utc&.iso8601(6) },
    "created_at" => ->(time) { time.utc.iso8601(6) },
    "updated_at" => ->(time) { time.utc.iso8601(6) }
  }.freeze

  # The validation context of a writer's create (EntryCreate).
  CREATE = :writer_create

  # The entry's columns `audited` records on TimesheetEntry today, so an
  # entry audit row records the same changes (§3.4).
  AUDITED = %w[
    duration work_date note bill_status review_status project_id user_id agent_id
    source source_metadata proof_url proof_metadata discarded_at
  ].freeze

  # What TimesheetEntry checks and normalizes today (app/models/timesheet_entry.rb),
  # the same values, so a writer's command is accepted, rewritten or refused
  # exactly as before.
  SOURCES = %w[manual cli mcp automation import].freeze
  SOURCE_METADATA_KEYS = %w[tool skill mcp_server].freeze
  SOURCE_METADATA_MAX_LENGTH = 100
  PROOF_METADATA_MAX_KEYS = 20
  PROOF_METADATA_MAX_LENGTH = 200
  MAX_DURATION = 6_000_000
  MAX_PROOF_URL_LENGTH = 2000

  has_many :reservations, dependent: :restrict_with_exception
  has_many :audits, class_name: "EntryAudit", dependent: :restrict_with_exception
  has_many :outbox_snapshots, dependent: :restrict_with_exception

  # The facts of the entry's project the gateway resolved and signed
  # (entry_api.json#/$defs/token_claims project): what TimesheetEntry reads
  # through `project` today. Timekeeping holds no catalogue (§3.2).
  attr_accessor :project_facts

  # In TimesheetEntry's order, so the errors come in its order and the
  # gateway's first full message is today's message (§5.1).
  before_validation :ensure_bill_status_is_set, :ensure_review_status_is_set, on: CREATE
  before_validation :ensure_bill_status_is_not_billed, on: CREATE
  before_validation :normalize_source_fields, :normalize_proof_metadata, on: CREATE

  validates :duration, :work_date, :bill_status, :review_status, presence: true, on: CREATE
  validates :duration, numericality: { less_than_or_equal_to: MAX_DURATION, greater_than_or_equal_to: 0.0 }, on: CREATE
  validates :source, inclusion: { in: SOURCES }, on: CREATE
  validates :proof_url, length: { maximum: MAX_PROOF_URL_LENGTH }, allow_blank: true, on: CREATE
  validate :validate_billable_project, on: CREATE

  scope :of_company, ->(company_id) { where(company_id:) }
  scope :kept, -> { where(discarded_at: nil) }

  # The full entry every entry API response carries
  # (common.json#/$defs/entry). Preload `reservations`, or each entry reads
  # its own.
  def to_contract
    { "id" => id, "company_id" => company_id, "version" => version }
      .merge(FIELDS.index_with { |field| FORMATS.fetch(field, :itself.to_proc).call(public_send(field)) })
      .merge("locked" => locked?)
  end

  # True exactly when the entry holds a reservation with edit_lock (§7.1),
  # as the shared rule decides it.
  def locked?
    TimekeepingReservations.locked?(id, reservations.map(&:to_value))
  end

  private

    def ensure_bill_status_is_set
      return if bill_status.present? || project_facts.nil?

      self.bill_status = project_facts.fetch("billable") ? "unbilled" : "non_billable"
    end

    # A10: an agent's entry waits for review.
    def ensure_review_status_is_set
      if agent_id.present?
        self.review_status = "pending_review" if review_status.blank? || review_status == "not_required"
        return
      end

      self.review_status = "not_required" if review_status.blank?
    end

    def ensure_bill_status_is_not_billed
      errors.add(:timesheet_entry, I18n.t("errors.create_billed_entry")) if bill_status == "billed"
    end

    def validate_billable_project
      return unless !project_facts&.fetch("billable") && bill_status == "unbilled"

      errors.add(:base, I18n.t("errors.validate_billable_project"))
    end

    # A10's source rewrite among them: mcp when the metadata names an MCP server.
    def normalize_source_fields
      self.source_metadata = normalized_source_metadata
      self.source = inferred_source
    end

    def normalize_proof_metadata
      self.proof_metadata = normalized_proof_metadata
    end

    def normalized_source_metadata
      return {} unless source_metadata.is_a?(Hash)

      source_metadata.deep_stringify_keys
        .slice(*SOURCE_METADATA_KEYS)
        .transform_values { |value| value.to_s.strip.presence&.slice(0, SOURCE_METADATA_MAX_LENGTH) }
        .compact_blank
    end

    def normalized_proof_metadata
      return {} unless proof_metadata.is_a?(Hash)

      proof_metadata.deep_stringify_keys.each_with_object({}).with_index do |((key, value), kept), index|
        break kept if index >= PROOF_METADATA_MAX_KEYS

        normalized = normalized_proof_metadata_value(value)
        next if normalized.blank? && normalized != false && normalized != 0

        kept[key.to_s.slice(0, SOURCE_METADATA_MAX_LENGTH)] = normalized
      end
    end

    def normalized_proof_metadata_value(value)
      case value
      when Numeric, TrueClass, FalseClass then value
      else value.to_s.strip.presence&.slice(0, PROOF_METADATA_MAX_LENGTH)
      end
    end

    def inferred_source
      return "import" if source.to_s.downcase == "import"
      return "mcp" if source_metadata["mcp_server"].present?
      return "automation" if source_metadata["tool"].present?

      normalized = (source.to_s.presence || "manual").downcase
      SOURCES.include?(normalized) ? normalized : "manual"
    end
end
