# frozen_string_literal: true

# The shared reservation decision table (docs/architecture/timekeeping-soa.md
# §7.2, §11.1). It is plain Ruby in its own package, outside the autoload
# paths, read by the prepared application's reservation provider.
require Rails.root.join("packages/timekeeping_reservations/lib/timekeeping_reservations").to_s

# The key Timekeeping and this application share to sign and verify their
# tokens (docs/architecture/timekeeping-soa.md §6.1, §11.2). It is a
# credential, so it comes from the process environment and never from a
# checked-in file. Unset, no Timekeeping token verifies.
Rails.configuration.x.timekeeping.token_key = ENV["TIMEKEEPING_TOKEN_KEY"]

# Where Timekeeping serves its internal API (§11.2: TIMEKEEPING_URL, a plain
# value). Unset, nothing in this application calls Timekeeping.
Rails.configuration.x.timekeeping.url = ENV["TIMEKEEPING_URL"]
