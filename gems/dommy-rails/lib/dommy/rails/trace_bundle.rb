# frozen_string_literal: true

module Dommy
  module Rails
    # Saves a failed example's trace as a self-contained bundle under
    # tmp/dommy_traces/ (via Dommy::Rack::Trace#save), named after the example
    # so re-runs of the same example overwrite their previous bundle instead
    # of piling up. Never raises — diagnostics must not mask the real failure.
    module TraceBundle
      ROOT = "tmp/dommy_traces"

      module_function

      def save_for_failure(trace, id:, description: nil, location: nil, root: ROOT)
        return nil unless trace.respond_to?(:save)

        dir = ::File.join(root, slug(id))
        trace.save(dir, status: "failed", metadata: {
          "example" => description, "location" => location
        }.compact)
        dir
      rescue StandardError
        nil
      end

      # "./spec/browser/posts_spec.rb[1:2]" -> "spec-browser-posts_spec-rb-1-2"
      def slug(id)
        id.to_s.sub(%r{\A\./}, "").gsub(/[^A-Za-z0-9_]+/, "-").squeeze("-").delete_suffix("-")
      end
    end
  end
end
