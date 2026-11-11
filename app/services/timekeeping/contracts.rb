# frozen_string_literal: true

require "json_schemer"

# The Timekeeping contracts of docs/architecture/timekeeping-soa.md §5, read
# from their one source of truth in packages/timekeeping_reservations/contracts/v1.
# This application narrows what Timekeeping sends it against them before
# reading it, and the consumer-side fakes in spec/support check against the
# same documents.
module Timekeeping::Contracts
  DIR = Rails.root.join("packages/timekeeping_reservations/contracts/v1")
  PROBLEM_BASE = "https://contracts.timekeeping.internal/problems/"

  class << self
    def document(name)
      documents.fetch(name.to_s)
    end

    # Every mismatch between payload and the definition at pointer in the
    # named contract; empty when the payload matches.
    def errors(name, pointer, payload)
      schema(name).ref(pointer).validate(payload).pluck("error")
    end

    def problem_type(slug)
      "#{PROBLEM_BASE}#{slug}"
    end

    private

      def documents
        @documents ||= DIR.glob("*.json").to_h { |path| [path.basename(".json").to_s, JSON.parse(path.read).freeze] }
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
