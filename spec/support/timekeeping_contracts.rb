# frozen_string_literal: true

require "json_schemer"
require "jwt"

# The three Timekeeping contracts of docs/architecture/timekeeping-soa.md §5
# (entry API, prepare/commit/abort, entry snapshot), read from their one source
# of truth in packages/timekeeping_reservations/contracts/v1, and the helpers
# their consumer-side fakes share: schema validation, the operation table and
# the HS256 tokens of §6.1.
module TimekeepingContracts
  DIR = Rails.root.join("packages/timekeeping_reservations/contracts/v1")
  BASE_URI = "https://contracts.timekeeping.internal/v1/"
  PROBLEM_BASE = "https://contracts.timekeeping.internal/problems/"
  NAMES = %i[entry_api reservation_api entry_snapshot].freeze
  TOKEN_TTL = 60.seconds
  TEST_TOKEN_KEY = "timekeeping-contract-test-key"

  # What an entry holds when a writer leaves a column out: today's column
  # defaults, and the review and bill status a plain entry gets.
  ENTRY_DEFAULTS = {
    "agent_id" => nil, "note" => "", "bill_status" => "unbilled", "review_status" => "not_required",
    "locked" => false, "source" => "manual", "source_metadata" => {}, "proof_url" => nil,
    "proof_metadata" => {}, "external_run_id" => nil, "external_session_id" => nil, "discarded_at" => nil
  }.freeze

  # A request or response that does not match its contract.
  class Violation < StandardError; end

  Operation = Data.define(:contract, :name, :verb, :path, :mutating, :request, :query, :responses) do
    # The path parameters when this operation serves the request, else nil.
    def match(verb_name, request_path)
      return unless verb_name == verb

      Regexp.new("\\A#{path.gsub(/\{(\w+)\}/, '(?<\1>[^/]+)')}\\z").match(request_path)&.named_captures
    end

    def path_for(**params)
      path.gsub(/\{(\w+)\}/) { params.fetch(Regexp.last_match(1).to_sym) }
    end
  end

  class << self
    def document(name)
      documents.fetch(name.to_s)
    end

    # Validates payload against the definition at pointer in the named
    # contract, and raises Violation listing every mismatch.
    def validate!(name, pointer, payload)
      errors = schema(name).ref(pointer).validate(payload).pluck("error")
      raise Violation, "#{name}#{pointer}: #{errors.join('; ')}" if errors.any?

      payload
    end

    def valid?(name, pointer, payload)
      schema(name).ref(pointer).valid?(payload)
    end

    def operations
      @operations ||= NAMES.flat_map do |contract|
        document(contract).fetch("x-operations").map do |name, operation|
          Operation.new(
            contract:,
            name: name.to_sym,
            verb: operation.fetch("method"),
            path: operation.fetch("path"),
            mutating: operation.fetch("mutating"),
            request: operation["request"],
            query: operation["query"],
            responses: operation.fetch("responses")
          )
        end
      end
    end

    def operation(name)
      operations.find { |operation| operation.name == name } or raise KeyError, "no operation #{name}"
    end

    def headers(contract)
      document(contract).fetch("x-headers")
    end

    def problem_type(slug)
      "#{PROBLEM_BASE}#{slug}"
    end

    # Signs claims as the shared-key HS256 token of §6.1, stamping its 60 s TTL.
    def sign(claims, key: TEST_TOKEN_KEY, now: Time.current)
      JWT.encode(claims.merge("iat" => now.to_i, "exp" => (now + TOKEN_TTL).to_i), key, "HS256")
    end

    # A valid user token for the entry and reservation APIs; overrides replace
    # whole claims.
    def user_token(company_id:, key: TEST_TOKEN_KEY, now: Time.current, **overrides)
      claims = {
        "sub" => "user:1", "aud" => "timekeeping", "company_id" => company_id, "role" => "admin",
        "timesheet_edit_days" => 7, "actor" => { "type" => "user", "agent_id" => nil }, "writer" => "web",
        "project" => nil, "request_id" => SecureRandom.uuid
      }.merge(overrides.transform_keys(&:to_s))
      validate!(:entry_api, "#/$defs/token_claims", claims.merge("iat" => now.to_i, "exp" => now.to_i))
      sign(claims, key:, now:)
    end

    def decode(token, key:, audience:)
      JWT.decode(token, key, true, algorithm: "HS256", aud: audience, verify_aud: true).first
    end

    private

      def documents
        @documents ||= DIR.glob("*.json").to_h { |path| [path.basename(".json").to_s, JSON.parse(path.read)] }
      end

      def schema(name)
        @schemas ||= {}
        @schemas[name.to_s] ||= JSONSchemer.schema(
          document(name),
          ref_resolver: ->(uri) { document(File.basename(uri.path, ".json")) }
        )
      end
  end
end
