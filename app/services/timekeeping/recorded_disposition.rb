# frozen_string_literal: true

# The recorded disposition of the pre-flight's unlocked links
# (docs/architecture/timekeeping-soa.md §10.4), as the first cutover takes it:
# the ids of the kept invoices whose unlocked links map to an active
# reservation with no edit lock (§7.4).
#
# A disposition is recorded by invoice number per company name, as the seed
# disposition is (spec/fixtures/timekeeping/seed_disposition.yml, the one for
# the two seeded businesses of the local demo): entry and invoice ids follow
# the database sequences and differ between runs, numbers do not. Every
# invoice it names must resolve to exactly one invoice; anything else raises
# Unresolved, so a disposition that no longer matches the data is never
# applied in part. Whether every unlocked link is disposed of is the
# checkpoint's to check (Timekeeping::LegacyCheckpoint::Undisposed).
module Timekeeping::RecordedDisposition
  SEED = "spec/fixtures/timekeeping/seed_disposition.yml"

  # The only disposition §10.4 defines for an unlocked link.
  UNLOCKED_LINKS = "active_without_edit_lock"

  # The file names something the data does not hold, or not exactly once.
  class Unresolved < StandardError; end

  # A relative `path` is taken from the application's root.
  def self.unlocked_link_invoice_ids(path = SEED)
    unlocked_links = YAML.safe_load_file(Rails.root.join(path)).fetch("unlocked_links")
    disposition = unlocked_links.fetch("disposition")
    raise Unresolved, "#{path}: unlocked links disposed of as #{disposition.inspect}, expected #{UNLOCKED_LINKS}" unless disposition == UNLOCKED_LINKS

    unlocked_links.fetch("invoices").flat_map { |company, numbers| invoice_ids(path, company, numbers) }
  end

  def self.invoice_ids(path, company, numbers)
    found = Invoice.joins(:company).where(companies: { name: company }, invoice_number: numbers)
      .pluck(:invoice_number, :id).group_by(&:first)
    unresolved = numbers.uniq.reject { |number| found.fetch(number, []).one? }
    raise Unresolved, "#{path}: #{company} #{unresolved.join(', ')} is not exactly one invoice" if unresolved.any?

    numbers.uniq.map { |number| found.fetch(number).sole.last }
  end
  private_class_method :invoice_ids
end
