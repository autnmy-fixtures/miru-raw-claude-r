# frozen_string_literal: true

# The shared contracts (docs/architecture/timekeeping-soa.md §5) in
# packages/timekeeping_reservations/contracts/v1, the same documents the
# existing application's clients and fakes read. What Timekeeping accepts is
# checked against them, so the contract is the one definition of a request.
module Contracts
  def self.document(name)
    documents.fetch(name.to_s)
  end

  # The errors of `payload` against the definition at `pointer` of contract
  # `name`, such as "#/$defs/list_query" of :entry_api. Empty when it conforms.
  def self.errors(name, pointer, payload)
    schemer(name).ref(pointer).validate(payload).map { |error| error.fetch("error") }
  end

  def self.schemer(name)
    (@schemers ||= {})[name.to_s] ||= JSONSchemer.schema(
      document(name),
      ref_resolver: ->(uri) { document(File.basename(uri.path, ".json")) }
    )
  end
  private_class_method :schemer

  def self.documents
    @documents ||= Rails.configuration.x.timekeeping.contracts_dir.glob("*.json")
      .to_h { |path| [path.basename(".json").to_s, JSON.parse(path.read)] }
      .freeze
  end
  private_class_method :documents
end
