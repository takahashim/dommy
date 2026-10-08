# frozen_string_literal: true

module Dommy
  module Js
    # Resolves a JS constructor by interface name for reverse construction
    # (`new Event(...)`, `new DOMException(...)`). The window object is the
    # source for most constructors — it exposes them via __js_get__ — while a
    # few not on the window are provided directly. Engine-agnostic.
    #
    # A *resolver*, not a store: it holds no map and looks each name up live
    # via the window. Named distinctly from Dommy::Bridge::ConstructorRegistry
    # (the abstract name -> Bridge::Constructor map), which is a different thing.
    class ConstructorResolver
      # The window whose __js_get__ exposes Event/CustomEvent/MouseEvent/… .
      attr_writer :source

      def initialize
        @source = nil
      end

      # An object responding to __js_new__ for `name`, or nil if `name` isn't
      # constructable (the bridge then makes the JS side throw).
      def resolve(name)
        if @source.respond_to?(:__js_get__)
          ctor = @source.__js_get__(name)
          return ctor if ctor.respond_to?(:__js_new__)
        end
        extra(name)
      end

      # The static/class method names of `name`'s constructor (URL.parse, …),
      # or [] when it has none. They belong to the interface, not to a window,
      # so they are worked out once per process for each kind of window: every
      # page load asks for all ~200 seeded interfaces, and resolving them
      # through the window each time cost a millisecond a page.
      def static_names(name)
        key = [@source.class, name]
        STATIC_NAMES.fetch(key) do
          ctor = resolve(name)
          names = ctor.respond_to?(:__js_class_method_names__) ? Array(ctor.__js_class_method_names__).freeze : EMPTY
          STATIC_NAMES[key] = names
        end
      end

      EMPTY = [].freeze
      STATIC_NAMES = {}
      private_constant :EMPTY, :STATIC_NAMES

      private

      # Constructors the window doesn't expose.
      def extra(name)
        case name
        when "DOMException"
          return unless defined?(Dommy::DOMException)

          Dommy::Bridge::Constructor.new { |args| Dommy::DOMException.new(args[0], args[1] || "Error") }
        end
      end
    end
  end
end
