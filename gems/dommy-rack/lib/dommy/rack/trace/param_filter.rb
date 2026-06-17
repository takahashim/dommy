# frozen_string_literal: true

module Dommy
  module Rack
    class Trace
      # Masks sensitive form / request parameters by key name before they land
      # in a trace artifact. A key whose name matches any configured matcher
      # (Regexp or exact String) has its value replaced with FILTERED. Owns the
      # masking *policy* so the Trace only decides *when* to record params, not
      # *how* to redact them.
      class ParamFilter
        # Parameter names matching any of these are masked so a password / token
        # never lands in a trace artifact. Construct with your own matchers to
        # override (dommy-rails passes Rails' filter_parameters).
        DEFAULT = [/pass/i, /secret/i, /token/i, /api[-_]?key/i, /auth/i, /csrf/i].freeze
        FILTERED = "[FILTERED]"

        def initialize(matchers = DEFAULT)
          @matchers = matchers
        end

        # Turn ordered [name, value] form pairs into a masked hash. A non-pairs
        # shape (already a hash / scalar) falls through to recursive masking.
        def form_params(params)
          return mask(params) unless ordered_pairs?(params)

          params.each_with_object({}) do |(name, value), out|
            out[name] = filtered?(name) ? FILTERED : value
          end
        end

        # Recursively mask sensitive values by key name.
        def mask(params)
          case params
          when Hash
            params.each_with_object({}) do |(key, value), out|
              out[key] = filtered?(key) ? FILTERED : mask(value)
            end
          when Array
            params.map { |value| mask(value) }
          else
            params
          end
        end

        def filtered?(key)
          name = key.to_s
          @matchers.any? { |matcher| matcher.is_a?(Regexp) ? matcher.match?(name) : name == matcher.to_s }
        end

        private

        def ordered_pairs?(params)
          params.is_a?(Array) && params.all? { |p| p.is_a?(Array) && p.size == 2 }
        end
      end
    end
  end
end
