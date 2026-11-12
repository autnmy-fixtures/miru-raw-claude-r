# frozen_string_literal: true

# The provider side of the contract tests (docs/architecture/timekeeping-soa.md
# §12.3): what Timekeeping answers is checked against the shared schemas in
# packages/timekeeping_reservations/contracts/v1, the same documents the
# existing application's consumer and fakes read.
module Contracts
  def contract_errors(name, pointer, payload)
    schemer = JSONSchemer.schema(
      contract_document(name),
      ref_resolver: ->(uri) { contract_document(File.basename(uri.path, ".json")) }
    )
    schemer.ref(pointer).validate(payload).map { |error| error.fetch("error") }
  end

  def contract_document(name)
    JSON.parse(Rails.configuration.x.timekeeping.contracts_dir.join("#{name}.json").read)
  end
end

RSpec.configure { |config| config.include Contracts }
