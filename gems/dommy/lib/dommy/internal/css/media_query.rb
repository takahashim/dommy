# frozen_string_literal: true

module Dommy
  module Internal
    module CSS
      # A Media Queries Level 4 subset evaluator for `matchMedia` and
      # friends. Queries are matched against an Environment snapshot
      # rather than a real device.
      #
      # Supported: media types (all/screen true, anything else false),
      # `not` / `only` prefixes, `and` chains, comma-separated OR lists,
      # `not` before a single condition, `(feature: value)` and
      # `(feature)` boolean contexts, and the range syntax for
      # width/height (`(width >= 600px)`, `(400px <= width <= 800px)`).
      #
      # Deliberately given up: the `or` combinator, nested parentheses
      # (`(not (width))`, general `<media-condition>` grouping), calc(),
      # and most discrete features beyond the ones listed in
      # FEATURE_VALUES below. Any query we cannot parse — including one
      # using `or` — evaluates to false, mirroring the spec's "unknown
      # query becomes `not all`" rule; we never raise.
      module MediaQuery
        module_function

        Environment = Struct.new(
          :viewport_width, :viewport_height, :device_pixel_ratio,
          :prefers_color_scheme, :prefers_reduced_motion, :hover, :pointer,
          keyword_init: true
        ) do
          def self.default
            new(viewport_width: 1280, viewport_height: 720, device_pixel_ratio: 1.0,
                prefers_color_scheme: "light", prefers_reduced_motion: "no-preference",
                hover: "hover", pointer: "fine")
          end
        end

        DEFAULT = Environment.default.freeze

        # Valid values for the discrete features we support; anything
        # else is treated as unparseable (query becomes false).
        FEATURE_VALUES = {
          "prefers-color-scheme" => %w[light dark],
          "prefers-reduced-motion" => %w[no-preference reduce],
          "hover" => %w[none hover],
          "any-hover" => %w[none hover],
          "pointer" => %w[none coarse fine],
          "any-pointer" => %w[none coarse fine]
        }.freeze

        # Evaluates a media query list. Comma-separated queries OR
        # together: the list matches if any single query matches. The
        # empty string is the empty query list, which matches (this is
        # what `matchMedia("")` does in browsers).
        def match?(text, environment = DEFAULT)
          text = text.to_s.strip
          return true if text.empty?

          # Commas cannot appear inside our supported conditions, so a
          # plain split is safe.
          text.split(",", -1).any? { |query| query_match?(query.strip, environment) }
        end

        # --- single query ---------------------------------------------

        def query_match?(query, env)
          tokens = tokenize(query)
          return false if tokens.nil? || tokens.empty?

          i = 0
          negate_query = false
          if tokens[0] == "not"
            negate_query = true
            i = 1
          elsif tokens[0] == "only"
            # `only` is only valid immediately before a media type
            # (`only screen`); `only (condition)` is a parse error.
            return false unless tokens[1].is_a?(String)

            i = 1
          end
          return false if i >= tokens.size

          # First segment: a media type word, or a leading condition.
          first = tokens[i]
          if first.is_a?(String)
            return false if %w[and not only or].include?(first)

            result = first == "all" || first == "screen"
            i += 1
          else
            result = evaluate_condition(first[1], env)
            return false if result.nil?

            i += 1
          end

          # Remaining segments: `and [not] ( ... )` repeated. Anything
          # else (notably `or`) makes the whole query unparseable.
          while i < tokens.size
            return false unless tokens[i] == "and"

            i += 1
            negate_condition = false
            if tokens[i] == "not"
              negate_condition = true
              i += 1
            end
            token = tokens[i]
            return false unless token.is_a?(Array)

            value = evaluate_condition(token[1], env)
            return false if value.nil?

            value = !value if negate_condition
            result &&= value
            i += 1
          end

          negate_query ? !result : result
        end

        # Splits a query into lower-cased keyword strings and
        # `[:cond, inner]` pairs for parenthesized conditions. Returns
        # nil when the query contains anything else (stray characters,
        # nested or unbalanced parentheses).
        def tokenize(query)
          tokens = []
          rest = query
          until (rest = rest.lstrip).empty?
            if rest.start_with?("(")
              close = rest.index(")")
              return nil if close.nil?

              inner = rest[1...close]
              return nil if inner.include?("(") # nested parens unsupported

              tokens << [:cond, inner.strip.downcase]
              rest = rest[(close + 1)..]
            elsif (match = rest.match(/\A[a-z][a-z0-9-]*/i))
              tokens << match[0].downcase
              rest = rest[match[0].length..]
              return nil unless rest.empty? || rest.start_with?("(") || rest.match?(/\A\s/)
            else
              return nil
            end
          end
          tokens
        end

        # --- conditions ------------------------------------------------

        # `inner` is the lower-cased text between parentheses. Returns
        # true/false, or nil when the condition cannot be interpreted.
        def evaluate_condition(inner, env)
          return nil if inner.empty?

          if inner.match?(/[<>]/) || (inner.include?("=") && !inner.include?(":"))
            evaluate_range(inner, env)
          elsif inner.include?(":")
            name, _, value = inner.partition(":")
            evaluate_feature(name.strip, value.strip, env)
          else
            evaluate_boolean_feature(inner, env)
          end
        end

        def evaluate_feature(name, value, env)
          case name
          when "width", "min-width", "max-width"
            px = parse_length(value)
            px && compare_with_prefix(name, env.viewport_width, px)
          when "height", "min-height", "max-height"
            px = parse_length(value)
            px && compare_with_prefix(name, env.viewport_height, px)
          when "orientation"
            case value
            when "portrait" then env.viewport_height >= env.viewport_width
            when "landscape" then env.viewport_width > env.viewport_height
            end
          when "aspect-ratio", "min-aspect-ratio", "max-aspect-ratio"
            evaluate_aspect_ratio(name, value, env)
          when "prefers-color-scheme"
            FEATURE_VALUES[name].include?(value) ? env.prefers_color_scheme == value : nil
          when "prefers-reduced-motion"
            FEATURE_VALUES[name].include?(value) ? env.prefers_reduced_motion == value : nil
          when "hover", "any-hover"
            FEATURE_VALUES[name].include?(value) ? env.hover == value : nil
          when "pointer", "any-pointer"
            FEATURE_VALUES[name].include?(value) ? env.pointer == value : nil
          when "resolution", "min-resolution", "max-resolution"
            dppx = parse_resolution(value)
            dppx && compare_with_prefix(name, env.device_pixel_ratio, dppx)
          end
        end

        def evaluate_boolean_feature(name, env)
          case name
          when "width" then env.viewport_width > 0
          when "height" then env.viewport_height > 0
          when "hover", "any-hover" then env.hover != "none"
          when "pointer", "any-pointer" then env.pointer != "none"
          end
        end

        # `(aspect-ratio: a/b)` — compare width/height against a/b
        # without floating point: width * b <=> a * height.
        def evaluate_aspect_ratio(name, value, env)
          match = value.match(%r{\A(\d+)\s*/\s*(\d+)\z})
          return nil unless match

          a = Integer(match[1], 10)
          b = Integer(match[2], 10)
          return nil if a.zero? || b.zero?

          compare_with_prefix(name, env.viewport_width * b, a * env.viewport_height)
        end

        # Range syntax, single (`width >= 600px`, `600px <= width`) or
        # double (`400px <= width <= 800px`). width/height only.
        def evaluate_range(inner, env)
          parts = inner.split(/(<=|>=|<|>|=)/).map(&:strip)
          case parts.size
          when 3
            left, op, right = parts
            if (actual = range_feature_value(left, env))
              value = parse_length(right)
              value && compare(actual, op, value)
            elsif (actual = range_feature_value(right, env))
              value = parse_length(left)
              value && compare(value, op, actual)
            end
          when 5
            low, op1, name, op2, high = parts
            actual = range_feature_value(name, env)
            return nil unless actual
            return nil unless (%w[< <=].include?(op1) && %w[< <=].include?(op2)) ||
                              (%w[> >=].include?(op1) && %w[> >=].include?(op2))

            low_px = parse_length(low)
            high_px = parse_length(high)
            return nil unless low_px && high_px

            compare(low_px, op1, actual) && compare(actual, op2, high_px)
          end
        end

        def range_feature_value(name, env)
          case name
          when "width" then env.viewport_width
          when "height" then env.viewport_height
          end
        end

        def compare(left, op, right)
          case op
          when "<" then left < right
          when "<=" then left <= right
          when ">" then left > right
          when ">=" then left >= right
          when "=" then left == right
          end
        end

        # min- prefix means "at least", max- means "at most", bare name
        # means exact equality.
        def compare_with_prefix(name, actual, target)
          if name.start_with?("min-")
            actual >= target
          elsif name.start_with?("max-")
            actual <= target
          else
            actual == target
          end
        end

        # --- value parsing ---------------------------------------------

        # Lengths in px; em/rem are converted at the canonical 16px.
        # A bare 0 (no unit) is a valid length; any other unitless
        # number is not.
        def parse_length(value)
          return 0.0 if value.match?(/\A0+(?:\.0+)?\z/)

          match = value.match(/\A(\d+(?:\.\d+)?)(px|em|rem)\z/)
          return nil unless match

          number = Float(match[1])
          match[2] == "px" ? number : number * 16
        end

        # Resolutions normalized to dppx; dpi divides by 96.
        def parse_resolution(value)
          match = value.match(/\A(\d+(?:\.\d+)?)(x|dppx|dpi)\z/)
          return nil unless match

          number = Float(match[1])
          match[2] == "dpi" ? number / 96 : number
        end
      end
    end
  end
end
