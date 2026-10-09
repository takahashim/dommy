# frozen_string_literal: true

require_relative "../css_source"

module Dommy
  module Internal
    module CSS
      # Tarjan's strongly connected components over the var()-reference graph,
      # used to find the custom-property names that participate in a dependency
      # cycle. The DFS state is one instance rather than a six-key Hash threaded
      # through every recursive call.
      class DependencyCycles
        # `graph` is name => [referenced names].
        def initialize(graph)
          @graph = graph
          @index = 0
          @indices = {}
          @lowlink = {}
          @on_stack = {}
          @stack = []
          @cyclic = {}
        end

        # The names in a cycle: the members of every strongly connected
        # component of size > 1, plus any self-referencing property
        # (`--a: var(--a)`).
        def cyclic_nodes
          @graph.each_key { |name| strongconnect(name) unless @indices.key?(name) }
          @cyclic
        end

        private

        # One node of Tarjan's SCC algorithm.
        def strongconnect(node)
          @indices[node] = @lowlink[node] = @index
          @index += 1
          @stack.push(node)
          @on_stack[node] = true

          @graph[node].each do |neighbour|
            if !@indices.key?(neighbour)
              strongconnect(neighbour)
              @lowlink[node] = [@lowlink[node], @lowlink[neighbour]].min
            elsif @on_stack[neighbour]
              @lowlink[node] = [@lowlink[node], @indices[neighbour]].min
            end
          end

          return unless @lowlink[node] == @indices[node]

          component = []
          loop do
            popped = @stack.pop
            @on_stack[popped] = false
            component << popped
            break if popped == node
          end
          if component.length > 1 || @graph[component.first].include?(component.first)
            component.each { |member| @cyclic[member] = true }
          end
        end
      end

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

        # Where var()'s name argument ends — the first comma outside every
        # bracket, string and comment — is CssSource's answer, the same one the
        # parser uses, so a name the parser read as `{a, b}` is not substituted
        # against as `{a`.

        module_function

        def contains_var?(value)
          value.to_s.match?(VAR_PATTERN)
        end

        # Substitute every var(--name[, fallback]) in `value` using `lookup`
        # (callable: name -> resolved value, or nil when the property is unset
        # or cyclic — in which case the fallback is used). Returns the
        # substituted string, or nil when invalid at computed-value time (an
        # unmatched paren, or a var() with no fallback to a missing property).
        def substitute(value, lookup, depth = 0)
          return nil if depth > 32 # runaway guard

          source = CssSource.new(value)
          out = +""
          index = 0
          # A var() inside a string or a comment is text: `"var(--x)"` is copied.
          while (call = source.next_function("var", index))
            start, close = call
            return nil unless close

            out << source.slice(index, start)
            name, fallback = split_args(source.slice(start + 4, close))
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
          out << source.slice(index, source.length)
        end

        # An element's computed custom properties: `inherited` ("--name" =>
        # computed value, its var()s substituted where it was declared) with
        # `declared` ("--name" => the element's own raw value) resolved over it.
        # Only the declared values are resolved, and only they can form a
        # cycle — an inherited value references nothing — so a page's root
        # palette is not resolved again for every element under it. A declared
        # value that is invalid (cyclic / unresolvable) drops the property.
        #
        # Cycles are detected up front on the dependency graph (the strongly
        # connected components): every property in a cycle is the guaranteed-
        # invalid value, fallback notwithstanding (css-variables-1 §3.1). A
        # property that merely *references* a cyclic/unset property still uses
        # its var() fallback — so the same DFS that mishandles secondary cycles
        # (a property in two overlapping cycles) is replaced by SCC analysis.
        def resolve_declared(inherited, declared)
          return inherited if declared.empty?

          cyclic = cyclic_properties(declared)
          resolved = {}
          resolve = lambda do |name|
            next inherited[name] unless declared.key?(name)
            next resolved[name] if resolved.key?(name)
            next (resolved[name] = nil) if cyclic[name]

            value = declared[name]
            resolved[name] = contains_var?(value) ? substitute(value, resolve) : value
          end

          result = inherited.dup
          declared.each_key do |name|
            value = resolve.call(name)
            value.nil? ? result.delete(name) : result[name] = value
          end
          result
        end

        # The custom-property names that participate in a dependency cycle: the
        # members of every strongly connected component of size > 1, plus any
        # self-referencing property (`--a: var(--a)`). Tarjan's SCC over the
        # var()-reference graph.
        def cyclic_properties(values)
          graph = {}
          values.each do |name, value|
            # A value without var() references nothing; most of a utility
            # sheet's custom properties are such plain values.
            graph[name] = contains_var?(value) ? references(value).select { |ref| values.key?(ref) }.uniq : []
          end

          DependencyCycles.new(graph).cyclic_nodes
        end

        # The custom-property names a value depends on for cycle detection: the
        # FIRST argument of each top-level var(). Fallback references don't
        # count — a cycle that exists only in an unused fallback is not a cycle
        # (csswg-drafts#11500), so `var(--x, var(--y))` depends on --x only.
        def references(value)
          source = CssSource.new(value)
          refs = []
          index = 0
          while (call = source.next_function("var", index))
            start, close = call
            break unless close

            name, = split_args(source.slice(start + 4, close))
            refs << name
            index = close + 1
          end
          refs
        end

        # var()'s arguments split at the first top-level comma: "--name ,
        # fallback" -> ["--name", "fallback"], with a nil fallback when there is
        # no comma (distinct from the empty-but-valid `var(--x,)` fallback).
        # Public because the parser asks the same question at parse time.
        def split_args(inner)
          name, fallback = CssSource.new(inner).partition_top_level(",")
          return [inner.strip, nil] unless name

          [name.strip, fallback.strip]
        end

        private_class_method :cyclic_properties, :references
      end
    end
  end
end
