# frozen_string_literal: true

module Dommy
  module Internal
    module CSS
      # var() substitution for custom properties (css-variables-1).
      # Substitution happens at computed-value time: first the custom
      # properties resolve among themselves (with cycle detection), then
      # regular property values substitute against the resolved set.
      module CustomProperties
        # The CSS function name is ASCII case-insensitive; the preceding
        # character guard keeps identifiers like `novar(` from matching.
        VAR_PATTERN = /(?<![\w-])var\(/i

        # <custom-property-name>: a dashed ident. Ident code points are ASCII
        # letters, digits, "_", "-" and everything non-ASCII (css-syntax-3 §4.2);
        # escapes aside, which no caller writes.
        CUSTOM_PROPERTY_NAME = /\A--[\w\-\u0080-\u{10FFFF}]*\z/

        # Brackets of every kind open a level, so a top-level comma is one that
        # no "(", "[" or "{" is still open at. The same rule the parser applies
        # when it decides where var()'s name argument ends — asked in two places,
        # it has to be answered the same way, or a name the parser read as
        # `{a, b}` would be substituted against as `{a`.
        OPENING_BRACKETS = "([{"
        CLOSING_BRACKETS = ")]}"

        module_function

        def contains_var?(value)
          value.to_s.match?(VAR_PATTERN)
        end

        # Resolve var() inside the custom property values themselves.
        # `values` is "--name" => raw value; returns "--name" => substituted
        # value with invalid (cyclic / unresolvable) entries dropped.
        #
        # Cycles are detected up front on the dependency graph (the strongly
        # connected components): every property in a cycle is the guaranteed-
        # invalid value, fallback notwithstanding (css-variables-1 §3.1). A
        # property that merely *references* a cyclic/unset property still uses
        # its var() fallback — so the same DFS that mishandles secondary cycles
        # (a property in two overlapping cycles) is replaced by SCC analysis.
        def resolve_all(values)
          cyclic = cyclic_properties(values)
          resolved = {}

          resolve = lambda do |name|
            next resolved[name] if resolved.key?(name)
            next (resolved[name] = nil) if cyclic[name]

            value = values[name]
            next (resolved[name] = nil) if value.nil?

            resolved[name] = substitute(value, resolve)
          end

          values.each_key { |name| resolve.call(name) }
          resolved.compact
        end

        # Substitute every var(--name[, fallback]) in `value` using `lookup`
        # (callable: name -> resolved value, or nil when the property is unset
        # or cyclic — in which case the fallback is used). Returns the
        # substituted string, or nil when invalid at computed-value time (an
        # unmatched paren, or a var() with no fallback to a missing property).
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
            # The parser keeps `var(--x ())` and `var({--x})`, because var()'s
            # first argument is only read as a custom property name here, after
            # substitution. A name that does not parse makes the declaration
            # invalid at computed-value time, fallback or no fallback.
            return nil unless CUSTOM_PROPERTY_NAME.match?(name)

            replacement = lookup.call(name)

            if replacement.nil?
              return nil if fallback.nil?

              replacement = substitute(fallback, lookup, depth + 1)
              return nil if replacement.nil?
            end

            out << replacement
            index = close + 1
          end
          out
        end

        # The custom-property names that participate in a dependency cycle: the
        # members of every strongly connected component of size > 1, plus any
        # self-referencing property (`--a: var(--a)`). Tarjan's SCC over the
        # var()-reference graph.
        def cyclic_properties(values)
          graph = {}
          values.each_key { |name| graph[name] = references(values[name]).select { |ref| values.key?(ref) }.uniq }

          state = {index: 0, indices: {}, lowlink: {}, on_stack: {}, stack: [], cyclic: {}}
          graph.each_key { |name| strongconnect(name, graph, state) unless state[:indices].key?(name) }
          state[:cyclic]
        end

        # One node of Tarjan's SCC algorithm.
        def strongconnect(node, graph, state)
          state[:indices][node] = state[:lowlink][node] = state[:index]
          state[:index] += 1
          state[:stack].push(node)
          state[:on_stack][node] = true

          graph[node].each do |neighbour|
            if !state[:indices].key?(neighbour)
              strongconnect(neighbour, graph, state)
              state[:lowlink][node] = [state[:lowlink][node], state[:lowlink][neighbour]].min
            elsif state[:on_stack][neighbour]
              state[:lowlink][node] = [state[:lowlink][node], state[:indices][neighbour]].min
            end
          end

          return unless state[:lowlink][node] == state[:indices][node]

          component = []
          loop do
            popped = state[:stack].pop
            state[:on_stack][popped] = false
            component << popped
            break if popped == node
          end
          if component.length > 1 || graph[component.first].include?(component.first)
            component.each { |member| state[:cyclic][member] = true }
          end
        end

        # The custom-property names a value depends on for cycle detection: the
        # FIRST argument of each top-level var(). Fallback references don't
        # count — a cycle that exists only in an unused fallback is not a cycle
        # (csswg-drafts#11500), so `var(--x, var(--y))` depends on --x only.
        def references(value)
          refs = []
          index = 0
          while index < value.length
            unless value[index, 4].casecmp("var(").zero? &&
                   (index.zero? || !value[index - 1].match?(/[\w-]/))
              index += 1
              next
            end

            close = matching_paren_index(value, index + 3)
            break unless close

            name, = split_args(value[(index + 4)...close])
            refs << name
            index = close + 1
          end
          refs
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

        # var()'s arguments split at the first top-level comma: "--name ,
        # fallback" -> ["--name", "fallback"], with a nil fallback when there is
        # no comma (distinct from the empty-but-valid `var(--x,)` fallback).
        # Public because the parser asks the same question at parse time.
        def split_args(inner)
          depth = 0
          inner.each_char.with_index do |char, index|
            depth += 1 if OPENING_BRACKETS.include?(char)
            depth -= 1 if CLOSING_BRACKETS.include?(char)
            return [inner[0...index].strip, inner[(index + 1)..].strip] if char == "," && depth.zero?
          end
          [inner.strip, nil]
        end
      end
    end
  end
end
