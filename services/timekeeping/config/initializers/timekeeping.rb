# frozen_string_literal: true

# The shared library of docs/architecture/timekeeping-soa.md §11.1: the
# reservation decision table (§7.2) and the contracts (§5). Timekeeping reads
# the same copy as the existing application; there is no second one.
packages = Rails.root.join("../../packages").expand_path
require packages.join("timekeeping_reservations/lib/timekeeping_reservations").to_s
Rails.configuration.x.timekeeping.contracts_dir = packages.join("timekeeping_reservations/contracts/v1")

# The key Timekeeping and the existing application share to sign and verify
# their tokens (§6.1, §11.2). It is a credential, so it comes from the process
# environment and never from a checked-in file.
Rails.configuration.x.timekeeping.token_key = ENV["TIMEKEEPING_TOKEN_KEY"]

# Where the existing application takes entry snapshots (§5.4, §11.2:
# EXISTING_APP_URL, a plain value). The relay delivers there.
Rails.configuration.x.timekeeping.existing_app_url = ENV["EXISTING_APP_URL"]
