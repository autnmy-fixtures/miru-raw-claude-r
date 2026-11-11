# frozen_string_literal: true

abort "Demo seeds are disabled in production." if Rails.env.production?

require "faker"

Faker::Config.random = Random.new(2025)
Faker::UniqueGenerator.clear

START_DATE = Date.new(2025, 1, 1)
# Fixed, so every seed produces the same entries, invoices and report totals.
END_DATE = Date.parse(ENV.fetch("MIRU_SEED_AS_OF", "2026-10-23"))
PASSWORD = ENV.fetch("MIRU_SEED_PASSWORD", "password")

def phone(number)
  number.to_s.gsub(/[^0-9+]/, "")[0, 15]
end

def money(cents)
  BigDecimal(cents.to_s) / 100
end

def ensure_address!(addressable, attributes)
  address = addressable.addresses.first_or_initialize
  address.update!(attributes)
  address
end

def ensure_notification_preference!(user, company)
  preference = NotificationPreference.find_or_initialize_by(user:, company:)
  preference.update!(
    notification_enabled: true,
    invoice_email_notifications: true,
    payment_email_notifications: true,
    timesheet_reminder_enabled: true,
    unsubscribed_from_all: false
  )
end

def ensure_user!(company:, first_name:, last_name:, email:, roles:, current_workspace: true, super_admin: false)
  user = User.find_or_initialize_by(email:)
  user.assign_attributes(
    first_name:,
    last_name:,
    password: PASSWORD,
    password_confirmation: PASSWORD,
    confirmed_at: Time.current,
    current_workspace_id: current_workspace ? company.id : user.current_workspace_id
  )
  user.save!

  Employment.find_or_create_by!(company:, user:)
  user.current_workspace = company if current_workspace
  user.save!

  user.roles.where(resource: company).find_each do |role|
    user.remove_role(role.name.to_sym, company)
  end

  roles.each do |role|
    user.add_role(role, company) unless user.has_role?(role, company)
  end

  user.add_role(:super_admin) if super_admin && !user.has_role?(:super_admin)

  ensure_address!(
    user,
    address_type: "current",
    address_line_1: "100 Example Way",
    address_line_2: "Suite #{100 + user.id.to_i}",
    city: "Springfield",
    state: "OR",
    country: "US",
    pin: "97477"
  )

  if user.devices.blank?
    user.devices.create!(
      company_id: company.id,
      device_type: "laptop",
      name: "MacBook Pro",
      serial_number: "MBP-#{user.id.to_s.rjust(4, '0')}"
    )
  end

  if user.previous_employments.blank?
    user.previous_employments.create!(company_name: "Example Corp", role: "Engineer")
  end

  ensure_notification_preference!(user, company)
  user
end

def ensure_client!(company:, name:, email:, phone_number:, member: nil)
  client = company.clients.find_or_initialize_by(email:)
  client.update!(
    name:,
    phone: phone(phone_number),
    currency: company.base_currency
  )

  ensure_address!(
    client,
    address_type: "permanent",
    address_line_1: "#{name} HQ",
    address_line_2: "Accounts Payable",
    city: "San Francisco",
    state: "CA",
    country: "US",
    pin: "94105"
  )

  if member
    ClientMember.find_or_create_by!(company:, client:, user: member)
  end

  client
end

def ensure_project!(client:, name:, description:, billable: true)
  project = client.projects.find_or_initialize_by(name:)
  project.update!(description:, billable:)
  project
end

def ensure_project_member!(project:, user:, hourly_rate:)
  membership = ProjectMember.find_or_initialize_by(project:, user:)
  membership.update!(hourly_rate:)
  membership
end

def seeded_holidays_for(year)
  [
    { date: Date.new(year, 1, 1), name: "New Years Day", category: :national },
    { date: Date.new(year, 1, 20), name: "Martin Luther King Jr Day", category: :national },
    { date: Date.new(year, 2, 17), name: "Presidents Day", category: :optional },
    { date: Date.new(year, 5, 26), name: "Memorial Day", category: :national },
    { date: Date.new(year, 6, 19), name: "Juneteenth", category: :national },
    { date: Date.new(year, 7, 4), name: "Independence Day", category: :national },
    { date: Date.new(year, 9, 1), name: "Labor Day", category: :national },
    { date: Date.new(year, 10, 13), name: "Columbus Day", category: :optional },
    { date: Date.new(year, 11, 27), name: "Thanksgiving", category: :national },
    { date: Date.new(year, 12, 25), name: "Christmas Day", category: :national }
  ]
end

# --- Fork & Leaf Salads: a fictional salad shop and catering business --------
#
# Every person, client and vendor below is fictional, and every mailbox is on a
# reserved .example domain (RFC 2606), so no mail can reach a person. The data
# is fixed to AS_OF, so the same seed always produces the same entries,
# invoices and report totals.

company = Company.find_or_initialize_by(name: "Fork & Leaf Salads")
company.update!(
  address: "212 Market Row, Springfield, OR 97477",
  business_phone: phone("+1 4155550100"),
  base_currency: "USD",
  standard_price: 4500,
  fiscal_year_end: "Dec",
  date_format: "MM-DD-YYYY",
  country: "US",
  timezone: "(GMT-08:00) America/Los_Angeles",
  bank_name: "Example Bank",
  bank_account_number: "0000000000",
  bank_routing_number: "000000000",
  bank_swift_code: "XXXXUS00",
  tax_id: "00-0000000",
  vat_number: "US-000000",
  gst_number: "GST-00000",
  plan_tier: "paid",
  billing_exempt: true
)

ensure_address!(
  company,
  address_type: "permanent",
  address_line_1: "212 Market Row",
  address_line_2: "Kitchen and office",
  city: "Springfield",
  state: "OR",
  country: "US",
  pin: "97477"
)

puts "Company ready: #{company.name}"

STAFF_DOMAIN = "forkandleaf.example"

owner = ensure_user!(company:, first_name: "Dana", last_name: "Whitfield", email: "dana@#{STAFF_DOMAIN}", roles: [:owner])
admin = ensure_user!(company:, first_name: "Luis", last_name: "Ortega", email: "luis@#{STAFF_DOMAIN}", roles: [:admin])
book_keeper = ensure_user!(company:, first_name: "Grace", last_name: "Lin", email: "grace@#{STAFF_DOMAIN}", roles: [:book_keeper])
prep_lead = ensure_user!(company:, first_name: "Mateo", last_name: "Reyes", email: "mateo@#{STAFF_DOMAIN}", roles: [:employee])
packer = ensure_user!(company:, first_name: "Aisha", last_name: "Bello", email: "aisha@#{STAFF_DOMAIN}", roles: [:employee])
driver = ensure_user!(company:, first_name: "Sam", last_name: "Novak", email: "sam@#{STAFF_DOMAIN}", roles: [:employee])
catering_lead = ensure_user!(company:, first_name: "Keiko", last_name: "Tanaka", email: "keiko@#{STAFF_DOMAIN}", roles: [:employee])

brightline_contact = ensure_user!(company:, first_name: "Nora", last_name: "Patel", email: "nora@brightline.example", roles: [:client])
brightline_finance = ensure_user!(company:, first_name: "Ian", last_name: "Mercer", email: "ap@brightline.example", roles: [:client])
harbor_contact = ensure_user!(company:, first_name: "Owen", last_name: "Brooks", email: "owen@harborlegal.example", roles: [:client])
summit_contact = ensure_user!(company:, first_name: "Rina", last_name: "Cho", email: "rina@summitevents.example", roles: [:client])

staff = [owner, admin, prep_lead, packer, driver, catering_lead]
client_users = [brightline_contact, brightline_finance, harbor_contact, summit_contact]

puts "Users ready: #{([book_keeper] + staff + client_users).map(&:email).join(', ')}"

# Office clients buy recurring lunch contracts; event organizers buy catering.
brightline = ensure_client!(company:, name: "Brightline Software", email: brightline_finance.email, phone_number: "+1 4155550101", member: brightline_contact)
harbor = ensure_client!(company:, name: "Harbor Legal Group", email: harbor_contact.email, phone_number: "+1 4155550102", member: harbor_contact)
summit = ensure_client!(company:, name: "Summit Events Co.", email: summit_contact.email, phone_number: "+1 4155550103", member: summit_contact)
riverside = ensure_client!(company:, name: "Riverside Arts Council", email: "events@riversidearts.example", phone_number: "+1 4155550104")
kitchen = ensure_client!(company:, name: "Fork & Leaf (internal)", email: "kitchen@#{STAFF_DOMAIN}", phone_number: "+1 4155550105")

ClientMember.find_or_create_by!(company:, client: brightline, user: brightline_finance)
ClientMember.find_or_create_by!(company:, client: riverside, user: summit_contact)

office_lunch = [
  ensure_project!(client: brightline, name: "Brightline Office Lunch", description: "Recurring weekday lunch contract, billed monthly"),
  ensure_project!(client: harbor, name: "Harbor Legal Office Lunch", description: "Recurring office lunch contract, billed monthly")
]
catering = [
  ensure_project!(client: brightline, name: "Brightline All-Hands Catering", description: "Catering for quarterly all-hands meetings"),
  ensure_project!(client: summit, name: "Summit Launch Catering", description: "Launch-day catering engagement"),
  ensure_project!(client: summit, name: "Summit Conference Lunches", description: "Boxed lunches for a two-day conference"),
  ensure_project!(client: riverside, name: "Riverside Gala Catering", description: "Evening gala catering engagement")
]
kitchen_training = ensure_project!(client: kitchen, name: "Kitchen Training", description: "Internal, not billed to any client", billable: false)

# Hourly rates in cents, by person: what a client is billed for an hour of their time.
project_rates = {
  owner => 8500,
  admin => 6500,
  prep_lead => 4500,
  packer => 4000,
  driver => 4200,
  catering_lead => 5000
}

# Who works on what: the kitchen crew on every contract and engagement, the
# managers on catering engagements only.
crew = [prep_lead, packer, driver, catering_lead]
(office_lunch + catering).each do |project|
  members = catering.include?(project) ? crew + [owner, admin] : crew
  members.each { |user| ensure_project_member!(project:, user:, hourly_rate: project_rates.fetch(user)) }
end
crew.each { |user| ensure_project_member!(project: kitchen_training, user:, hourly_rate: 0) }

puts "Projects ready: #{office_lunch.size + catering.size + 1}"

[2025, 2026].each do |year|
  holiday = Holiday.find_or_initialize_by(company:, year:)
  holiday.update!(
    enable_optional_holidays: true,
    no_of_allowed_optional_holidays: 2,
    holiday_types: %w[national optional],
    time_period_optional_holidays: :per_year
  )

  seeded_holidays_for(year).each do |attrs|
    info = HolidayInfo.find_or_initialize_by(holiday:, date: attrs[:date])
    info.update!(name: attrs[:name], category: attrs[:category])
  end
end

leave_2025 = Leave.find_or_initialize_by(company:, year: 2025)
leave_2025.save!
leave_2026 = Leave.find_or_initialize_by(company:, year: 2026)
leave_2026.save!

leave_types = [
  { leave: leave_2025, name: "Vacation", icon: :vacation, color: :chart_blue, allocation_value: 15, allocation_period: :days, allocation_frequency: :per_year, carry_forward_days: 5 },
  { leave: leave_2025, name: "Sick Leave", icon: :medicine, color: :chart_green, allocation_value: 8, allocation_period: :days, allocation_frequency: :per_year, carry_forward_days: 0 },
  { leave: leave_2026, name: "Vacation", icon: :vacation, color: :chart_blue, allocation_value: 15, allocation_period: :days, allocation_frequency: :per_year, carry_forward_days: 5 },
  { leave: leave_2026, name: "Sick Leave", icon: :medicine, color: :chart_green, allocation_value: 8, allocation_period: :days, allocation_frequency: :per_year, carry_forward_days: 0 }
]

leave_type_records = leave_types.map do |attrs|
  leave_type = LeaveType.find_or_initialize_by(leave: attrs[:leave], name: attrs[:name])
  leave_type.update!(attrs.except(:leave))
  leave_type
end

[
  [prep_lead, Date.new(2025, 3, 14), "Vacation", 480],
  [packer, Date.new(2025, 6, 9), "Sick Leave", 480],
  [driver, Date.new(2025, 8, 22), "Vacation", 480],
  [catering_lead, Date.new(2026, 2, 6), "Vacation", 480]
].each do |user, leave_date, leave_name, duration|
  leave_record = leave_date.year == 2025 ? leave_2025 : leave_2026
  leave_type = leave_type_records.find { |record| record.leave == leave_record && record.name == leave_name }
  TimeoffEntry.find_or_create_by!(user:, leave_type:, leave_date:) { |entry| entry.duration = duration }
end

puts "Leave data ready"

# --- Time entries ---------------------------------------------------------
#
# What each person does, written into the entry's note.
DUTIES = {
  prep_lead => ["Salad prep and portioning", "Dressing and grain batch prep"],
  packer => ["Packing lunch orders", "Labeling and packing"],
  driver => ["Office delivery run", "Delivery and drop-off"],
  catering_lead => ["Catering setup", "Event service and breakdown"],
  owner => ["Client walkthrough and event lead"],
  admin => ["Event staffing and logistics"]
}.freeze

def duty_note(duties, user, day)
  list = duties.fetch(user)
  list[day.yday % list.size]
end

# Catering engagements happen on fixed event days.
EVENT_DAYS = {
  "Brightline All-Hands Catering" => [Date.new(2025, 3, 20), Date.new(2025, 6, 19), Date.new(2025, 9, 18), Date.new(2025, 12, 11), Date.new(2026, 3, 19), Date.new(2026, 6, 18), Date.new(2026, 9, 17)],
  "Summit Launch Catering" => [Date.new(2025, 10, 7), Date.new(2025, 10, 8), Date.new(2026, 10, 6), Date.new(2026, 10, 7)],
  "Summit Conference Lunches" => [Date.new(2026, 4, 14), Date.new(2026, 4, 15)],
  "Riverside Gala Catering" => [Date.new(2025, 11, 15), Date.new(2026, 5, 9)]
}.freeze

def seed_entry!(user:, project:, work_date:, duration:, note:, bill_status: :unbilled)
  entry = TimesheetEntry.find_or_initialize_by(user:, project:, work_date:)
  entry.update!(duration:, note:, bill_status:, locked: false)
  entry
end

(START_DATE..END_DATE).each do |day|
  next if day.saturday? || day.sunday?
  next if day.month == 12 && day.day > 22

  office_lunch.each_with_index do |project, index|
    crew.each do |user|
      next if (day.yday + user.id + index) % 4 == 0

      # Whole hours: 2 to 4 on a lunch day.
      duration = 120 + (((day.yday + user.id + index) % 3) * 60)
      seed_entry!(user:, project:, work_date: day, duration:, note: duty_note(DUTIES, user, day))
    end
  end

  # Kitchen training: every other Friday, not billable.
  next unless day.friday? && day.cweek.even?

  crew.each do |user|
    seed_entry!(user:, project: kitchen_training, work_date: day, duration: 60, note: "Food safety and kitchen training", bill_status: :non_billable)
  end
end

catering.each do |project|
  EVENT_DAYS.fetch(project.name).select { |day| day <= END_DATE }.each do |day|
    project.project_members.includes(:user).map(&:user).each do |user|
      duration = [owner, admin].include?(user) ? 180 : 300
      seed_entry!(user:, project:, work_date: day, duration:, note: duty_note(DUTIES, user, day))
    end
  end
end

puts "Timesheet entries ready"

# --- Invoices -------------------------------------------------------------
#
# Office-lunch contracts are billed monthly with GROUPED lines: one line per
# person per month, linked to every entry it covers. Catering engagements are
# billed per event month with INDIVIDUAL lines, one per entry. Each invoice's
# stored figures come from its own lines, so they match what Miru recalculates.
#
# Status by month, relative to AS_OF: the current month is a draft (its entries
# lock); the previous two months were sent, and are overdue once past due, as
# the daily overdue job would mark them; the two before that were viewed and
# half paid; older months are paid. Entries on a sent, viewed, overdue or paid
# invoice are billed. Miru's own send action does not mark entries billed at
# this commit (observed), so the seed records the historical billed state
# directly.

def invoice_status_for(month, as_of, due_date)
  return :draft if month >= as_of.beginning_of_month
  return (due_date < as_of ? :overdue : :sent) if month > (as_of << 3).beginning_of_month
  return :viewed if month > (as_of << 5).beginning_of_month

  :paid
end

invoice_counter = 0
next_invoice_number = lambda do
  invoice_counter += 1
  "FL-#{invoice_counter.to_s.rjust(4, '0')}"
end

seed_invoice = lambda do |client:, month:, lines:, discount_cents: 0|
  subtotal_cents = lines.sum { |line| ((line[:quantity] / 60.0) * line[:rate_cents]).round }
  tax_cents = (subtotal_cents * 0.0875).round
  total_cents = subtotal_cents + tax_cents - discount_cents
  issue_date = month.end_of_month
  due_date = issue_date + 30.days
  status = invoice_status_for(month, END_DATE, due_date)
  paid_cents = { paid: total_cents, viewed: (total_cents * 0.5).round }.fetch(status, 0)

  invoice = Invoice.find_or_initialize_by(company:, invoice_number: next_invoice_number.call)
  invoice.update!(
    client:,
    issue_date:,
    due_date:,
    reference: "#{month.strftime('%Y%m')}-#{client.id}",
    amount: money(total_cents),
    tax: money(tax_cents),
    discount: money(discount_cents),
    amount_paid: money(paid_cents),
    amount_due: money(total_cents - paid_cents),
    outstanding_amount: money(total_cents - paid_cents),
    status:,
    currency: company.base_currency,
    base_currency_amount: money(total_cents),
    sent_at: status == :draft ? nil : issue_date + 1.day
  )

  invoice.invoice_line_items.destroy_all
  lines.each do |line|
    invoice.invoice_line_items.create!(
      name: line[:name],
      description: line[:description],
      date: line[:date],
      quantity: line[:quantity],
      rate: money(line[:rate_cents]),
      timesheet_entry_id: line[:timesheet_entry_id],
      linked_timesheet_entry_ids: line.fetch(:linked_timesheet_entry_ids, [])
    )
  end

  unless status == :draft
    entry_ids = lines.flat_map { |line| [line[:timesheet_entry_id], *line.fetch(:linked_timesheet_entry_ids, [])] }.compact
    TimesheetEntry.where(id: entry_ids).find_each { |entry| entry.update!(bill_status: :billed) }
  end

  if paid_cents.positive?
    payment = invoice.payments.find_or_initialize_by(name: "Payment #{invoice.invoice_number}")
    payment.update!(
      amount: money(paid_cents),
      transaction_date: issue_date + 10.days,
      transaction_type: :bank_transfer,
      payment_currency: company.base_currency
    )
  end
  invoice
end

month = START_DATE.beginning_of_month
while month <= END_DATE.beginning_of_month
  office_lunch.each do |project|
    entries = TimesheetEntry.kept.where(project:, work_date: month..month.end_of_month).order(:work_date).to_a
    next if entries.empty?

    lines = entries.group_by(&:user).map do |user, user_entries|
      {
        name: "#{project.name}: #{user.full_name}",
        description: "#{month.strftime('%B %Y')} lunch service, #{user_entries.size} days",
        date: month.end_of_month,
        quantity: user_entries.sum(&:duration).round,
        rate_cents: project_rates.fetch(user),
        linked_timesheet_entry_ids: user_entries.map(&:id)
      }
    end
    seed_invoice.call(client: project.client, month:, lines:, discount_cents: month.month == 12 ? 5000 : 0)
  end

  catering.group_by(&:client).each do |client, client_projects|
    entries = TimesheetEntry.kept.where(project: client_projects, work_date: month..month.end_of_month).order(:work_date, :id).to_a
    next if entries.empty?

    lines = entries.map do |entry|
      {
        name: "#{entry.project.name}: #{entry.user.full_name}",
        description: entry.note,
        date: entry.work_date,
        quantity: entry.duration.round,
        rate_cents: project_rates.fetch(entry.user),
        timesheet_entry_id: entry.id
      }
    end
    seed_invoice.call(client:, month:, lines:)
  end

  month = month.next_month
end

puts "Invoices and payments ready: #{invoice_counter}"

receipt_path = Rails.root.join("spec/fixtures/files/test-image.png")

expense_rows = [
  { user: prep_lead, category_name: "Supplies", vendor_name: "Valley Greens Produce", description: "Produce for a catering event", amount: 412_80, date: Date.new(2025, 10, 6), expense_type: :business, status: :paid, paid_at: Date.new(2025, 10, 10) },
  { user: packer, category_name: "Supplies", vendor_name: "Example Packaging Co.", description: "Compostable lunch boxes", amount: 268_40, date: Date.new(2026, 1, 12), expense_type: :business, status: :approved },
  { user: driver, category_name: "Travel", vendor_name: "Metro Van Rentals", description: "Extra van for a conference delivery", amount: 189_00, date: Date.new(2026, 4, 14), expense_type: :business, status: :submitted },
  { user: catering_lead, category_name: "Equipment", vendor_name: "Kitchen Supply Depot", description: "Chafing dishes for an evening gala", amount: 356_25, date: Date.new(2025, 11, 12), expense_type: :business, status: :paid, paid_at: Date.new(2025, 11, 20) },
  { user: admin, category_name: "Training", vendor_name: "Example Food Safety Institute", description: "Food handler certification", amount: 145_00, date: Date.new(2026, 2, 3), expense_type: :business, status: :rejected }
]

expense_rows.each_with_index do |attrs, index|
  expense = company.expenses.find_or_initialize_by(user: attrs[:user], date: attrs[:date], description: attrs[:description])
  expense.update!(
    amount: money(attrs[:amount]),
    category_name: attrs[:category_name],
    vendor_name: attrs[:vendor_name],
    expense_type: attrs[:expense_type],
    status: attrs[:status],
    paid_at: attrs[:paid_at]
  )

  next unless File.exist?(receipt_path)
  next if expense.receipts.attached?

  expense.receipts.attach(io: File.open(receipt_path), filename: "receipt-#{index + 1}.png", content_type: "image/png")
end

puts "Expenses ready"

# Stripe stays disconnected: the demo takes no payments.
company.payments_providers.find_or_initialize_by(name: "stripe").update!(
  name: "stripe", connected: false, enabled: false, accepted_payment_methods: %w[card ach]
)

Invitation.find_or_initialize_by(company:, recipient_email: "new.hire@#{STAFF_DOMAIN}").update!(
  sender: admin, first_name: "New", last_name: "Hire", role: :employee, accepted_at: nil, expired_at: 10.days.from_now
)
Invitation.find_or_initialize_by(company:, recipient_email: "planner@summitevents.example").update!(
  sender: admin, client: summit, first_name: "Event", last_name: "Planner", role: :client, accepted_at: nil, expired_at: 10.days.from_now
)

puts "Invitations ready"
# --- A second company, for company boundaries ------------------------------
#
# Copper Kettle Bakery, another fictional small business with its own staff,
# client, project, entries and one sent invoice. Fork & Leaf's book keeper keeps
# its books too, so one user belongs to both companies (her current workspace
# stays Fork & Leaf) and a workspace switch can be shown.

BAKERY_DOMAIN = "copperkettle.example"
bakery = Company.find_or_initialize_by(name: "Copper Kettle Bakery")
bakery.update!(
  address: "48 Mill Lane, Springfield, OR 97477",
  business_phone: phone("+1 4155550200"),
  base_currency: "USD",
  standard_price: 4000,
  fiscal_year_end: "Dec",
  date_format: "MM-DD-YYYY",
  country: "US",
  timezone: "(GMT-08:00) America/Los_Angeles",
  bank_name: "Example Bank",
  bank_account_number: "0000000000",
  bank_routing_number: "000000000",
  bank_swift_code: "XXXXUS00",
  plan_tier: "paid",
  billing_exempt: true
)
ensure_address!(bakery, address_type: "permanent", address_line_1: "48 Mill Lane", address_line_2: "Bakery", city: "Springfield", state: "OR", country: "US", pin: "97477")

bakery_owner = ensure_user!(company: bakery, first_name: "Hugo", last_name: "Brandt", email: "hugo@#{BAKERY_DOMAIN}", roles: [:owner])
baker = ensure_user!(company: bakery, first_name: "Lena", last_name: "Park", email: "lena@#{BAKERY_DOMAIN}", roles: [:employee])
# The shared book keeper: a member of both companies, still working in Fork & Leaf.
ensure_user!(company: bakery, first_name: "Grace", last_name: "Lin", email: book_keeper.email, roles: [:book_keeper], current_workspace: false)
cafe_contact = ensure_user!(company: bakery, first_name: "Paulo", last_name: "Silva", email: "paulo@northcafe.example", roles: [:client])

north_cafe = ensure_client!(company: bakery, name: "North Street Cafe", email: cafe_contact.email, phone_number: "+1 4155550201", member: cafe_contact)
pastry_supply = ensure_project!(client: north_cafe, name: "Cafe Pastry Supply", description: "Daily pastry delivery, billed monthly")
bakery_rates = { bakery_owner => 6000, baker => 3800 }
bakery_rates.each { |user, rate| ensure_project_member!(project: pastry_supply, user:, hourly_rate: rate) }

bakery_entries = (Date.new(2026, 9, 1)..Date.new(2026, 9, 30)).select { |day| day.tuesday? || day.thursday? }.flat_map do |day|
  bakery_rates.keys.map do |user|
    seed_entry!(user:, project: pastry_supply, work_date: day, duration: user == baker ? 240 : 60, note: user == baker ? "Early bake and delivery" : "Order planning")
  end
end

bakery_lines = bakery_entries.map do |entry|
  { name: "Cafe Pastry Supply: #{entry.user.full_name}", description: entry.note, date: entry.work_date, minutes: entry.duration.round, rate_cents: bakery_rates.fetch(entry.user), entry: }
end
bakery_subtotal = bakery_lines.sum { |line| ((line[:minutes] / 60.0) * line[:rate_cents]).round }
bakery_tax = (bakery_subtotal * 0.0875).round
bakery_invoice = Invoice.find_or_initialize_by(company: bakery, invoice_number: "CK-0001")
bakery_invoice.update!(
  client: north_cafe,
  issue_date: Date.new(2026, 9, 30),
  due_date: Date.new(2026, 10, 30),
  reference: "202609-CK",
  amount: money(bakery_subtotal + bakery_tax),
  tax: money(bakery_tax),
  discount: 0,
  amount_paid: 0,
  amount_due: money(bakery_subtotal + bakery_tax),
  outstanding_amount: money(bakery_subtotal + bakery_tax),
  status: :sent,
  currency: bakery.base_currency,
  base_currency_amount: money(bakery_subtotal + bakery_tax),
  sent_at: Date.new(2026, 10, 1)
)
bakery_invoice.invoice_line_items.destroy_all
bakery_lines.each do |line|
  bakery_invoice.invoice_line_items.create!(
    name: line[:name], description: line[:description], date: line[:date],
    quantity: line[:minutes], rate: money(line[:rate_cents]), timesheet_entry_id: line[:entry].id
  )
  line[:entry].update!(bill_status: :billed)
end

puts "Second company ready: #{bakery.name} (#{bakery_entries.size} entries, invoice #{bakery_invoice.invoice_number})"

puts "Seed complete (as of #{END_DATE})"
puts "Logins (the seed password is not printed):"
puts "- dana@#{STAFF_DOMAIN} (owner)"
puts "- luis@#{STAFF_DOMAIN} (admin)"
puts "- grace@#{STAFF_DOMAIN} (book keeper)"
puts "- mateo@, aisha@, sam@, keiko@#{STAFF_DOMAIN} (employees: prep, packing, delivery, catering setup)"
puts "- nora@brightline.example, ap@brightline.example, owen@harborlegal.example, rina@summitevents.example (clients)"
puts "- hugo@#{BAKERY_DOMAIN} (owner), lena@#{BAKERY_DOMAIN} (employee), paulo@northcafe.example (client): Copper Kettle Bakery"
puts "- grace@#{STAFF_DOMAIN} is book keeper in both companies"
