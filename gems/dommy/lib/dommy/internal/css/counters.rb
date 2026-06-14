# frozen_string_literal: true

module Dommy
  module Internal
    module CSS
      # CSS counters (CSS Lists 3 §4): computes the in-scope counter values at
      # every element from `counter-reset` / `counter-increment` / `counter-set`,
      # honoring nesting and scope, so `counter()` / `counters()` in generated
      # content can be resolved to text. Dommy renders no boxes, so the consumer
      # is the accessible name (generated-content text) rather than display.
      #
      # The computed value of `content` keeps `counter(...)` literal (per CSSOM),
      # so getComputedStyle is unaffected; only the rendered text equivalent
      # resolves counters. Counter properties on pseudo-elements themselves are
      # not honored (the common `li { counter-increment }` + `li::before {
      # content: counter() }` works because the value is computed at the element).
      module Counters
        module_function

        # element => { counter_name => [outermost..innermost values] } for the
        # whole document, computed in tree order. `counter()` reads the innermost
        # (last) value; `counters()` joins the whole stack.
        def build(document)
          result = {}.compare_by_identity
          root = document.respond_to?(:document_element) ? document.document_element : nil
          return result unless root

          walk(root, 0, Hash.new { |hash, key| hash[key] = [] }, result)
          result
        end

        # Depth-first in document order. Each counter instance records the depth
        # of its creating element. Returns the names this element *instantiated*
        # (pushed a new instance), so the parent can pop them once it finishes
        # all of its children — a counter's scope extends to its originating
        # element's following siblings (and their descendants), i.e. to the end
        # of the parent's child list.
        def walk(element, depth, state, result)
          created = apply_counter_ops(element, depth, state)
          result[element] = snapshot(state)

          children_created = []
          element_children(element).each { |child| children_created.concat(walk(child, depth + 1, state, result)) }
          children_created.reverse_each do |name|
            state[name].pop
            state.delete(name) if state[name].empty?
          end

          created
        end

        # Apply the element's counter properties (reset, then increment, then
        # set) to `state`, returning the names for which it pushed a new instance.
        # A counter-reset whose innermost in-scope counter was created at the same
        # depth (a preceding sibling at the same nesting level) resets that one in
        # place rather than nesting. counter-increment / counter-set on a name
        # with no in-scope counter implicitly create one (value 0) here.
        def apply_counter_ops(element, depth, state)
          style = computed_style_for(element)
          return [] unless style

          created = []
          counter_list(style["counter-reset"], 0).each do |name, value|
            created << name if reset_counter(state, name, value, depth)
          end
          counter_list(style["counter-increment"], 1).each do |name, value|
            created << name if ensure_counter(state, name, depth)
            state[name].last[:value] += value
          end
          counter_list(style["counter-set"], 0).each do |name, value|
            created << name if ensure_counter(state, name, depth)
            state[name].last[:value] = value
          end
          created
        end

        # Reset `name` to `value`. If the innermost in-scope counter was created
        # at this same depth (a sibling at the same level), reset it in place
        # (returns false — no new instance). Otherwise nest a new instance
        # (returns true).
        def reset_counter(state, name, value, depth)
          stack = state[name]
          if !stack.empty? && stack.last[:depth] == depth
            stack.last[:value] = value
            false
          else
            stack.push({value: value, depth: depth})
            true
          end
        end

        def ensure_counter(state, name, depth)
          return false unless state[name].empty?

          state[name].push({value: 0, depth: depth})
          true
        end

        def snapshot(state)
          state.each_with_object({}) do |(name, stack), snap|
            snap[name] = stack.map { |instance| instance[:value] } unless stack.empty?
          end
        end

        # Parse a `counter-reset` / `counter-increment` / `counter-set` value
        # into [name, integer] pairs. Each name may be followed by an integer
        # (else `default`). `none` / empty yield none.
        def counter_list(value, default)
          text = value.to_s.strip
          return [] if text.empty? || text.casecmp("none").zero?

          tokens = text.split(/\s+/)
          pairs = []
          index = 0
          while index < tokens.length
            name = tokens[index]
            index += 1
            next if reserved_counter_name?(name)

            if index < tokens.length && tokens[index].match?(/\A-?\d+\z/)
              amount = tokens[index].to_i
              index += 1
            else
              amount = default
            end
            pairs << [name, amount]
          end
          pairs
        end

        # CSS-wide keywords / `none` are not counter names.
        def reserved_counter_name?(name)
          %w[none inherit initial unset revert].include?(name.downcase)
        end

        def element_children(element)
          return [] unless element.respond_to?(:children)

          element.children.to_a
        end

        def computed_style_for(element)
          Cascade.computed_style(element)
        rescue StandardError
          nil
        end

        # ---- counter() / counters() resolution (generated-content text) ----

        # Replace each `counter()` / `counters()` in a `content` value with a
        # double-quoted CSS string of its resolved text, so the caller's normal
        # string handling (unescape) yields the value. `values` is the element's
        # { name => stack } from #build. (Separators containing `)` are a
        # documented limitation of the `[^)]` scan.)
        def substitute(content, values)
          content.gsub(/\bcounters?\([^)]*\)/i) { |function| quote(resolve_function(function, values)) }
        end

        def resolve_function(function, values)
          if (match = function.match(/\Acounter\(\s*([\w-]+)\s*(?:,\s*([\w-]+)\s*)?\)\z/i))
            stack = values[match[1]]
            format(stack ? stack.last : 0, match[2])
          elsif (match = function.match(/\Acounters\(\s*([\w-]+)\s*,\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*')\s*(?:,\s*([\w-]+)\s*)?\)\z/i))
            separator = unquote(match[2])
            (values[match[1]] || []).map { |value| format(value, match[3]) }.join(separator)
          else
            ""
          end
        end

        # Format a counter value per a `<counter-style>` name (a curated subset:
        # decimal, decimal-leading-zero, {lower,upper}-{alpha,latin,roman}). An
        # unsupported style or an out-of-range value falls back to decimal.
        ROMAN = [[1000, "m"], [900, "cm"], [500, "d"], [400, "cd"], [100, "c"], [90, "xc"],
                 [50, "l"], [40, "xl"], [10, "x"], [9, "ix"], [5, "v"], [4, "iv"], [1, "i"]].freeze

        def format(value, style)
          case style.to_s.downcase
          when "", "decimal" then value.to_s
          when "decimal-leading-zero" then value.between?(0, 9) ? "0#{value}" : value.to_s
          when "lower-alpha", "lower-latin" then alpha(value)&.downcase || value.to_s
          when "upper-alpha", "upper-latin" then alpha(value)&.upcase || value.to_s
          when "lower-roman" then roman(value)&.downcase || value.to_s
          when "upper-roman" then roman(value)&.upcase || value.to_s
          else value.to_s
          end
        end

        # Bijective base-26 (1 -> "a", 26 -> "z", 27 -> "aa"); nil for n < 1.
        def alpha(number)
          return nil if number < 1

          letters = +""
          while number.positive?
            number -= 1
            letters.prepend((("a".ord) + (number % 26)).chr)
            number /= 26
          end
          letters
        end

        # Lowercase Roman numerals for 1..3999; nil outside that range.
        def roman(number)
          return nil if number < 1 || number > 3999

          out = +""
          ROMAN.each do |value, symbol|
            while number >= value
              out << symbol
              number -= value
            end
          end
          out
        end

        def quote(text)
          %("#{text.gsub(/(["\\])/) { "\\#{Regexp.last_match(1)}" }}")
        end

        def unquote(token)
          inner = token[1...-1].to_s
          inner.gsub(/\\(.)/) { Regexp.last_match(1) }
        end
      end
    end
  end
end
