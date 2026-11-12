# frozen_string_literal: true

# One application/problem+json body (RFC 9457) as the contracts define it
# (docs/architecture/timekeeping-soa.md §5.1, common.json#/$defs/problem).
# Every error Timekeeping answers is one of these, so a client reads any
# non-2xx answer one way.
#
# The slug names the stable type. The types themselves are read from
# common.json, the one source of truth, so a slug the contract does not list
# cannot be built.
Problem = Data.define(:slug, :status, :detail, :retryable) do
  def self.types
    @types ||= JSON.parse(Rails.configuration.x.timekeeping.contracts_dir.join("common.json").read)
      .dig("$defs", "problem_type", "enum")
      .index_by { |type| type.split("/").last }
      .freeze
  end

  def initialize(slug:, status:, detail: nil, retryable: false)
    raise ArgumentError, "#{slug} is not a problem type of the contracts" unless self.class.types.key?(slug)

    super
  end

  def as_json(*)
    {
      "type" => self.class.types.fetch(slug),
      "title" => Rack::Utils::HTTP_STATUS_CODES.fetch(status),
      "status" => status,
      "detail" => detail,
      "retryable" => retryable
    }.compact
  end
end
