# frozen_string_literal: true

# The provider side of the contract tests (docs/architecture/timekeeping-soa.md
# §12.3): what Timekeeping answers is checked against the shared schemas in
# packages/timekeeping_reservations/contracts/v1, through the same Contracts
# module that checks what it accepts.
module ContractHelpers
  def contract_errors(name, pointer, payload) = Contracts.errors(name, pointer, payload)

  def contract_document(name) = Contracts.document(name)
end

RSpec.configure { |config| config.include ContractHelpers }
