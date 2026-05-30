# frozen_string_literal: true

require_relative "test_helper"

# Structural invariant for the JS bridge: a class's declared callable method
# names (`js_methods` / `JS_METHOD_NAMES`) MUST equal the string `when` arms of
# its own `__js_call__` dispatch. Drift in either direction is a silent host bug
# (an extra name returns nil when called; a missing name makes the method
# uncallable from JS). This test parses each `__js_call__` and enforces equality,
# and fails if a class gains an `__js_call__` without declaring its names.
#
# Uses RubyVM::AbstractSyntaxTree, so it only runs on MRI. (`.of(method)` fails
# under the Prism-default Ruby 4.0, so we parse the source file and locate the
# `def __js_call__` by its source line instead.)
if defined?(RubyVM::AbstractSyntaxTree) && RUBY_ENGINE == "ruby"
  class TestJsCallDispatchInvariant < Minitest::Test
    AST = RubyVM::AbstractSyntaxTree

    # Classes whose `__js_call__` is function-style (no `case method` dispatch)
    # or an internal bridge adapter — they expose no enumerable named methods.
    ALLOWLIST = %w[
      Dommy::Bridge::Callback
      Dommy::Bridge::Constructor
      Dommy::Bridge::PromiseConstructor
      Dommy::Bridge::PromiseSettler
      Dommy::FetchFn
      Dommy::DatasetMap
    ].freeze

    @file_ast = {}
    class << self
      def file_ast(path)
        @file_ast[path] ||= AST.parse_file(path)
      end
    end

    def own_call_classes
      ObjectSpace.each_object(Class).select do |k|
        k.name&.start_with?("Dommy::") &&
          begin
            k.instance_method(:__js_call__).owner == k
          rescue StandardError
            false
          end
      end
    end

    # The string literals of the outer `case method` dispatch in the class's own
    # __js_call__, in source order. Returns [] for a function-style __js_call__.
    def own_when_strings(klass)
      um = klass.instance_method(:__js_call__)
      file, line = um.source_location
      defn = find_defn(self.class.file_ast(file), line, :__js_call__)
      raise "no def __js_call__ at #{file}:#{line} for #{klass}" unless defn

      param = um.parameters.first&.last || :method
      dispatch = find_method_case(defn, param)
      dispatch ? when_strings(dispatch) : []
    end

    def find_defn(node, line, name)
      return node if node.type == :DEFN && node.children[0] == name && node.first_lineno == line

      node.children.each do |c|
        next unless c.is_a?(AST::Node)

        found = find_defn(c, line, name)
        return found if found
      end
      nil
    end

    # First `case` whose subject is the method-name parameter (skips nested
    # `case`s on other variables, which live inside `when` bodies).
    def find_method_case(node, param)
      return nil unless node.is_a?(AST::Node)

      if node.type == :CASE
        subj = node.children[0]
        if subj.is_a?(AST::Node) && %i[LVAR DVAR].include?(subj.type) && subj.children[0] == param
          return node
        end
      end
      node.children.each do |c|
        next unless c.is_a?(AST::Node)

        found = find_method_case(c, param)
        return found if found
      end
      nil
    end

    # Walks only the dispatch case's direct `when` clauses (never descends into
    # arm bodies, so nested `case`s are not collected). Flunks on a non-string
    # `when` (the name-list model can't represent it).
    def when_strings(case_node)
      out = []
      clause = case_node.children[1]
      while clause.is_a?(AST::Node) && clause.type == :WHEN
        conds = clause.children[0]
        nodes =
          if conds.is_a?(AST::Node) && %i[LIST ARRAY].include?(conds.type)
            conds.children.compact
          else
            [conds]
          end
        nodes.each do |cn|
          next unless cn.is_a?(AST::Node)

          flunk "non-string `when #{cn.type}` in dispatch" unless cn.type == :STR
          out << cn.children[0]
        end
        clause = clause.children[2]
      end
      out
    end

    # Sanity-check the AST walker against a known class.
    def test_walker_self_check
      assert_equal %w[add remove contains toggle replace item],
                   own_when_strings(Dommy::ClassList)
    end

    def test_declared_names_match_dispatch_when_arms
      own_call_classes.each do |klass|
        next if ALLOWLIST.include?(klass.name)
        next unless klass.const_defined?(:JS_METHOD_NAMES, false)

        declared = klass.const_get(:JS_METHOD_NAMES, false).map(&:to_s)
        arms = own_when_strings(klass)
        assert_equal arms.sort, declared.sort,
                     "#{klass}: js_methods declaration drifted from __js_call__ when-arms"
      end
    end

    def test_every_dispatcher_declares_or_is_allowlisted
      missing = own_call_classes.reject do |klass|
        ALLOWLIST.include?(klass.name) || klass.const_defined?(:JS_METHOD_NAMES, false)
      end
      assert_empty missing.map(&:name),
                   "classes own __js_call__ but declare no js_methods (add `js_methods` or allowlist)"
    end
  end
end
