# frozen_string_literal: true

module Dommy
  module Bridge
    # A JS constructor function as Ruby sees it: `new X(...)` plus the static
    # methods hanging off it, and the table Window looks names up in. The
    # registry maps to these, so they share a file.

    # Block-as-constructor adapter — invoking `__js_new__(args)`
    # calls the wrapped block with `args` and returns whatever the
    # block produces. Used by Window to wire up `new Event(init)`,
    # `new CustomEvent(init)`, etc. without hand-rolling a class
    # for each constructor.
    class Constructor
      def initialize(&block)
        @block = block
        @class_methods = {}
      end

      def __js_new__(args)
        @block.call(args)
      end

      # Register a class-level method (e.g. `URL.createObjectURL`)
      # that JS bridges resolve via `__js_call__` on the constructor
      # itself. Returns self for chaining.
      def define_class_method(name, &block)
        @class_methods[name.to_s] = block
        self
      end

      # A name outside the registered statics is not a method of this
      # constructor, and answering nil would make `URL.notAThing()` read as a
      # call that returned null rather than one that should not have compiled.
      def __js_call__(method, args)
        handler = @class_methods[method.to_s]
        raise TypeError, "#{method} is not a function" unless handler

        handler.call(args)
      end

      # Names of the registered class-level (static) methods, so a JS host can
      # expose them on the constructor function (e.g. `URL.createObjectURL`).
      def __js_class_method_names__
        @class_methods.keys
      end
    end

    # Maps JS global constructor names (e.g. "Event", "URL", "XMLHttpRequest")
    # to their `Bridge::Constructor` instances. Window builds one and routes
    # `__js_get__` name lookups through it, instead of carrying one ivar plus
    # one `when` arm per constructor.
    class ConstructorRegistry
      def initialize(map)
        @map = map.freeze
      end

      def [](name)
        @map[name]
      end

      def key?(name)
        @map.key?(name)
      end

      # The set of constructor names, e.g. for host-side enumeration / tests.
      def names
        @map.keys
      end
    end
  end
end
