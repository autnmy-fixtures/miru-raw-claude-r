# frozen_string_literal: true

# The user-hard-delete proof of docs/architecture/timekeeping-soa.md §12.4,
# against the two running applications of the local demo (§11.2):
#
#   User hard delete refused once extraction has begun. With the relay
#   paused, create a first entry for a user, then attempt the super-admin
#   destroy: it is refused before its audit row and before any dependent
#   effect, the user and the entry are unchanged, and the relay then resumes
#   and projects the entry. Repeat after a rollback to the prepared
#   application: still refused.
#
# It runs under either owner that writes entries outside timesheet_entries,
# with admission open: Timekeeping (after the first cutover or a re-cutover),
# whose relay is the timekeeping-relay service, and the prepared application
# (after a rollback), whose local relay runs in miru-jobs. #relay names the
# service that holds the current owner's relay. bin/timekeeping-demo
# user-delete-refused stops that service, runs #paused, starts it again and
# runs #resumed; run once after a cutover and once after a rollback, it is
# the whole of §12.4's case. Both halves name their writes after the same
# run, so the second finds what the first wrote. On each seeded business:
#
#   paused   a new user of the business (an employee on its billable project,
#            with an agent of theirs, made here in process, as the
#            alternating-writers driver makes its agents) creates their first
#            entry over the public API, and their entry list shows it at
#            once; the projection (timesheet_entries) holds no row for it.
#            Then the super admin's DELETE /api/v1/users/:id must answer 422
#            with the handoff refusal, and the user, their agent, their entry
#            (as their entry list shows it) and the absence of a
#            super_admin_delete audit row must all be as before; the
#            projection still holds no row
#   resumed  the projection holds the entry, for that user, as written (the
#            relay caught up, and the users key it sits under held); then the
#            user discards the entry and it leaves their entry list
#
# The super admin is SuperAdmin's address. It is made here, confirmed and
# with the seeded users' password, when the demo has no such user, and
# employed with no role in the first business when it has no workspace, as
# token sign-in needs. If the
# projection already holds the entry while the relay should be stopped, the
# run fails: it would prove nothing. Any check that does not hold raises
# Failed. A run that finishes leaves, per business, the user (which cannot
# be deleted while the extraction is active: that is the point), its agent,
# and one discarded entry; one that fails leaves what it wrote for
# inspection.
class Timekeeping::UserDeleteRefusedCheck
  include Timekeeping::PublicApi

  class Failed < StandardError; end

  Entry = Struct.new(:id, :duration, :note, keyword_init: true)

  DURATION = 35.0
  HOURLY_RATE = 40
  DOMAIN = "timekeeping-demo.example"

  # The service each owner's relay runs in (docker-compose.timekeeping-demo.yml).
  RELAYS = { "timekeeping" => "timekeeping-relay", "monolith" => "miru-jobs" }.freeze

  # What a run may change: wait is how long, in seconds, a check waits on a
  # worker; tenants default to the seeded businesses.
  Options = Data.define(:wait, :tenants) do
    def initialize(wait: DEFAULT_WAIT, tenants: TENANTS) = super
  end

  # run: names the writes of one run, the same for both halves.
  def initialize(client:, password:, run:, logger: Rails.logger, options: Options.new)
    fail! "a run name is letters, digits and dashes, and #{run.inspect} is not" unless run.to_s.match?(/\A[a-zA-Z0-9-]+\z/)

    @client = client
    @password = password
    @run = run
    @logger = logger
    @options = options
    @sessions = {}
  end

  # The service to stop to pause the current owner's relay.
  def relay
    RELAYS.fetch(ensure_owner!.owner)
  end

  # While the current owner's relay is stopped.
  def paused
    ownership = ensure_owner!
    super_admin = ensure_super_admin!
    @options.tenants.each { |tenant| check_paused(prepare(tenant, super_admin)) }
    say "with the relay paused, the super-admin delete of a user with a first, unprojected entry was refused " \
        "on #{@options.tenants.size} businesses, under owner #{ownership.owner} at generation #{ownership.generation}"
  end

  # Once that relay runs again.
  def resumed
    ownership = ensure_owner!
    @options.tenants.each { |tenant| check_resumed(prepare(tenant, nil)) }
    say "once the relay resumed, the refused users' entries were projected on #{@options.tenants.size} businesses, " \
        "under owner #{ownership.owner} at generation #{ownership.generation}"
  end

  private

    def log_prefix = "user delete refused"

    def wait = @options.wait

    def ensure_owner!
      ownership = Timekeeping::Ownership.current
      return ownership if RELAYS.key?(ownership.owner) && ownership.state_open?

      fail! "the user-delete proof runs while Timekeeping or the prepared application owns the entries with " \
            "admission open (after a cutover or a rollback); ownership is #{ownership.summary}"
    end

    def note = "User delete refused #{@run}"

    def subject_email(tenant) = "delete-refused-#{@run.downcase}-#{tenant[:company].id}@#{DOMAIN}"

    # The business as PublicApi prepares it, with the run's user as
    # :subject, and the super admin as :super_admin when the half needs one.
    def prepare(tenant, super_admin)
      prepared = prepare_tenant(tenant)
      prepared.merge(subject: subject_email(prepared), super_admin: super_admin&.email)
    end

    # Token sign-in (Authenticable#legacy_token_active?) needs the user
    # employed in its current workspace, so a super admin with none is
    # employed, with no role, in the first business. The destroy reads no
    # role: SuperAdminUserPolicy reads only the address.
    def ensure_super_admin!
      email = SuperAdmin::SUPER_ADMIN_EMAILS.first
      user = User.find_by(email:) || User.create!(
        email:, first_name: "Super", last_name: "Admin", password: @password, password_confirmation: @password,
        confirmed_at: Time.current
      )
      fail! "#{email} is not a super admin here: it is not confirmed" unless user.super_admin?
      return user if user.current_workspace_id && user.employed_at?(user.current_workspace_id)

      company = prepare_tenant(@options.tenants.first).fetch(:company)
      Employment.find_or_create_by!(company:, user:)
      user.tap { user.update!(current_workspace_id: company.id) }
    end

    # A new employee of the business, on its billable project, with an agent
    # of theirs: the dependent effect a delete would have (User has_many
    # :agents, dependent: :destroy).
    def make_subject!(tenant)
      email = tenant[:subject]
      fail! "#{tenant[:name]}: #{email} already exists; give each run its own name" if User.exists?(email:)

      company = tenant[:company]
      user = User.create!(
        email:, first_name: "Delete", last_name: "Refused", password: @password, password_confirmation: @password,
        confirmed_at: Time.current, current_workspace_id: company.id
      )
      Employment.create!(company:, user:)
      user.add_role(:employee, company)
      ProjectMember.create!(project: tenant[:project], user:, hourly_rate: HOURLY_RATE)
      agent = Agent.create!(company:, user:, default_project: tenant[:project], name: "Delete refused #{@run}", provider: "user-delete-refused")
      [user, agent]
    end

    def check_paused(tenant)
      user, agent = make_subject!(tenant)
      fail! "#{tenant[:name]}: user #{user.id} already has entries; the proof needs their first" if user_entries?(user)

      entry = create_entry(tenant)
      id = entry.id
      fail! "#{tenant[:name]}: entry #{id} is not in its user's entry list at once" unless same?(entry, subject_list(tenant, user)[id])
      ensure_unprojected!(tenant, id)

      response = as(tenant, :super_admin).call(:delete, "/api/v1/users/#{user.id}")
      ensure_refused!(tenant, user, response)
      ensure_unchanged!(tenant, user, agent, entry)
      ensure_unprojected!(tenant, id)

      say "#{tenant[:name]}: the delete of user #{user.id}, whose first entry #{id} is not yet projected, was refused " \
          "with nothing changed"
    end

    def check_resumed(tenant)
      user = User.find_by(email: tenant[:subject]) || fail!("#{tenant[:name]}: no user #{tenant[:subject]}; run the paused half first")
      entry = find_entry(tenant, user)
      id = entry.id
      eventually("the projection holds entry #{id} for user #{user.id} as written") do
        row = TimesheetEntry.unscoped.find_by(id:)
        row && row.user_id == user.id && same?(entry, "note" => row.note, "duration" => row.duration)
      end
      say "#{tenant[:name]}: the projection caught up with entry #{id} of user #{user.id}"

      delete(tenant, :subject, "/api/v1/timesheet_entry/#{id}", "discard entry #{id}")
      eventually("entry #{id} leaves its user's entry list") { !subject_list(tenant, user).key?(id) }
      say "#{tenant[:name]}: discarded entry #{id}; user #{user.id} stays, as it cannot be deleted"
    end

    def user_entries?(user)
      TimesheetEntry.unscoped.exists?(user_id: user.id) || Timekeeping::Entry.exists?(user_id: user.id)
    end

    def ensure_refused!(tenant, user, response)
      expected = I18n.t("user.super_admin_delete.timekeeping_handoff")
      return if response.status == 422 && response.json["errors"] == expected

      fail! "#{tenant[:name]}: the super-admin delete of user #{user.id} answered #{response.status} " \
            "#{response.body.to_s.truncate(500)}, not 422 #{expected.inspect}"
    end

    # The refusal runs first in the destroy (§10.1): no audit row, and no
    # dependent effect.
    def ensure_unchanged!(tenant, user, agent, entry)
      fail! "#{tenant[:name]}: user #{user.id} was deleted" unless User.exists?(user.id)
      fail! "#{tenant[:name]}: agent #{agent.id} of user #{user.id} was destroyed" unless Agent.where(id: agent.id, user_id: user.id).exists?
      if Audited::Audit.exists?(action: "super_admin_delete", auditable_type: "User", auditable_id: user.id)
        fail! "#{tenant[:name]}: the refused delete of user #{user.id} left a super_admin_delete audit row"
      end
      return if same?(entry, subject_list(tenant, user)[entry.id])

      fail! "#{tenant[:name]}: entry #{entry.id} of user #{user.id} is not in their entry list as written after the refused delete"
    end

    # The projection is this application's timesheet_entries: the relay's
    # one destination (§3.2). A row there means the relay is not paused.
    def ensure_unprojected!(tenant, id)
      return unless TimesheetEntry.unscoped.exists?(id)

      fail! "#{tenant[:name]}: the projection already holds entry #{id}, so the relay is not paused " \
            "(stop the owner's relay first; bin/timekeeping-demo user-delete-refused does)"
    end

    def create_entry(tenant)
      response = as(tenant, :subject).call(:post, "/api/v1/timesheet_entry", body: entry_body(tenant, duration: DURATION, note:))
      expect_ok!(response, "create the first entry of #{tenant[:subject]}")
      Entry.new(id: response.json.dig("entry", "id"), duration: DURATION, note:)
    end

    def subject_list(tenant, user) = entry_list(tenant, role: :subject, user_id: user.id)

    # The one entry the paused half wrote, as the owner lists it.
    def find_entry(tenant, user)
      rows = subject_list(tenant, user).values.select { |row| row["note"] == note }
      fail! "#{tenant[:name]}: the entry list of user #{user.id} holds #{rows.size} entries noted #{note.inspect}, not one" unless rows.one?

      Entry.new(id: rows.first["id"], duration: DURATION, note:)
    end
end
