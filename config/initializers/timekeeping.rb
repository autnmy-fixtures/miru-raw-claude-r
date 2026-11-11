# frozen_string_literal: true

# The key Timekeeping and this application share to sign and verify their
# tokens (docs/architecture/timekeeping-soa.md §6.1, §11.2). It is a
# credential, so it comes from the process environment and never from a
# checked-in file. Unset, no Timekeeping token verifies.
Rails.configuration.x.timekeeping.token_key = ENV["TIMEKEEPING_TOKEN_KEY"]
