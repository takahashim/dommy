# frozen_string_literal: true

module Dommy
  module Internal
    module CSS
      # var() substitution for custom properties (css-variables-1).
      # Substitution happens at computed-value time: first the custom
      # properties resolve among themselves (with cycle detection), then
      # regular property values substitute against the resolved set.
      module CustomProperties
        # Unwinding marker for cycle detection: poisons every property on
        # the resolution stack up to (and including) the one named — a
        # cycle participant is invalid "fallback notwithstanding"
        # (css-variables-1 §3.1), while a mere *reference* to an invalid
        # property may still use its fallback.
        Cycle = Struct.new(:name)

        # The CSS function name is ASCII case-insensitive; the preceding
        # character guard keeps identifiers like `novar(` from matching.
        VAR_PATTERN = /(?<![\w-])var\(/i

        module_function

        def contains_var?(value)
          value.to_s.match?(VAR_PATTERN)
        end

        # Resolve var() inside the custom property values themselves.
        # `values` is "--name" => raw value; returns "--name" => substituted
        # value with invalid (cyclic / unresolvable) entries dropped.
        def resolve_all(values)
          resolved = {}
          visiting = {}

          resolve = lambda do |name|
            next resolved[name] if resolved.key?(name)
            next Cycle.new(name) if visiting[name]

            value = values[name]
            next resolved[name] = nil if value.nil?

            visiting[name] = true
            result = substitute(value, resolve)
            visiting.delete(name)

            if result.is_a?(Cycle)
              resolved[name] = nil
              # Keep poisoning the stack until the frame that started the
              # cycle; above it, the property is just "invalid".
              result.name == name ? nil : result
            else
              resolved[name] = result
            end
          end

          values.each_key { |name| resolve.call(name) }
          resolved.compact
        end

        # Substitute every var(--name[, fallback]) in `value` using `lookup`
        # (callable: name -> value / nil / Cycle). Returns the substituted
        # string, nil when invalid at computed-value time, or a Cycle being
        # unwound. The fallback (everything after the first top-level comma,
        # commas included) is itself substituted and may nest var().
        def substitute(value, lookup, depth = 0)
          return nil if depth > 32 # runaway guard

          out = +""
          index = 0
          while index < value.length
            at_var = value[index, 4].casecmp("var(").zero? &&
              (index.zero? || !value[index - 1].match?(/[\w-]/))
            unless at_var
              out << value[index]
              index += 1
              next
            end

            close = matching_paren_index(value, index + 3)
            return nil unless close

            name, fallback = split_args(value[(index + 4)...close])
            replacement = lookup.call(name)
            return replacement if replacement.is_a?(Cycle)

            if replacement.nil?
              return nil if fallback.nil?

              replacement = substitute(fallback, lookup, depth + 1)
              return replacement if replacement.is_a?(Cycle)
              return nil if replacement.nil?
            end

            out << replacement
            index = close + 1
          end
          out
        end

        def matching_paren_index(value, open_index)
          depth = 0
          index = open_index
          while index < value.length
            case value[index]
            when "(" then depth += 1
            when ")"
              depth -= 1
              return index if depth.zero?
            end
            index += 1
          end
          nil
        end

        # "--name , fallback" -> ["--name", "fallback"]; no comma -> nil
        # fallback (distinct from the empty-but-valid `var(--x,)` fallback).
        def split_args(inner)
          depth = 0
          inner.each_char.with_index do |ch, idx|
            depth += 1 if ch == "("
            depth -= 1 if ch == ")"
            return [inner[0...idx].strip, inner[(idx + 1)..].strip] if ch == "," && depth.zero?
          end
          [inner.strip, nil]
        end
      end
    end
  end
end
