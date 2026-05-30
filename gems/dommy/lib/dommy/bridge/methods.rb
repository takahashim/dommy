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
          own = names.map(&:to_s).freeze
          const_set(:JS_METHOD_NAMES, own) unless const_defined?(:JS_METHOD_NAMES, false)

          # Capture the ancestor's __js_method_names__ as a real method (if any)
          # at definition time. We can't use `super` here: classes like
          # StyleDeclaration define `method_missing`, so `super` would fall
          # through to it and return a CSS-property String instead of raising.
          parent =
            if superclass.method_defined?(:__js_method_names__)
              superclass.instance_method(:__js_method_names__)
            end

          define_method(:__js_method_names__) do
            base = parent ? parent.bind(self).call : []
            (base + own).uniq.freeze
          end
        end
      end
    end
  end
end
