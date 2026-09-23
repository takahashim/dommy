# frozen_string_literal: true

module Dommy
  module Bridge
    # Declares, in one line, the set of JS-callable method names a bridge class
    # routes through `__js_call__` (as opposed to data properties read via
    # `__js_get__`). The QuickJS host reads `__js_method_names__` once per
    # interface to decide which property names to expose as callable functions.
    #
    #   class Blob
    #     include Bridge::Methods
    #     js_methods %w[slice text arrayBuffer]
    #     def __js_call__(method, args) = ...
    #   end
    #
    # Subclasses compose automatically: a subclass's own `js_methods` are merged
    # with its ancestors' (ancestors first), so `__js_call__ ... else super`
    # chains stay in sync with the exposed names without a manual `super + own`.
    #
    # The per-class `JS_METHOD_NAMES` constant holds the class's OWN names; the
    # suite asserts it matches the class's own `__js_call__` `when` arms — see
    # test/test_js_call_dispatch_invariant.rb.
    module Methods
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # `extend` is per-singleton, so a subclass of an includer would not
        # inherit `js_methods`. Re-extend each subclass as it is defined.
        def inherited(subclass)
          super
          subclass.extend(ClassMethods)
        end

        def js_methods(names)
          @own_js_methods = names.map(&:to_s).freeze
          @js_method_names = nil # a declaration after a first read must win
          const_set(:JS_METHOD_NAMES, @own_js_methods) unless const_defined?(:JS_METHOD_NAMES, false)
          @own_js_methods
        end

        # The class's names plus its ancestors', ancestors first. Composed on
        # the CLASS, which is where the answer belongs: a per-instance method
        # could not use `super` to reach the ancestor's copy, because a class
        # like StyleDeclaration answers `method_missing` for any name and would
        # hand back a CSS property string instead. Walking `superclass` has no
        # such problem.
        def js_method_names
          @js_method_names ||= begin
            inherited_names = superclass.respond_to?(:js_method_names) ? superclass.js_method_names : []
            (inherited_names + own_js_methods).uniq.freeze
          end
        end

        def own_js_methods = @own_js_methods || []
      end

      # The bridge ABI reads this per interface to decide which property names
      # are callable functions.
      def __js_method_names__ = self.class.js_method_names
    end
  end
end
