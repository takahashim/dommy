# frozen_string_literal: true

module Dommy
  module Internal
    # IDL-attribute reflection for `HTMLElement` and `SVGElement` subclasses.
    #
    # Two layers:
    #
    # 1. **Instance helpers** (`reflected_string` / `set_reflected_string` /
    #    `reflected_boolean` / `set_reflected_boolean`) delegate to the host
    #    element's standard attribute API (`get_attribute` / `set_attribute` /
    #    `has_attribute?` / `remove_attribute`), so case-sensitivity is
    #    inherited from the host's namespace — HTML lowercases, SVG keeps the
    #    spec name (`viewBox`).
    #
    #    - **String**: property mirrors the attribute value. Missing → `""`.
    #    - **Boolean**: property is true iff the attribute is present. Setting
    #      true writes `""`; setting false removes the attribute.
    #
    # 2. **A class-level DSL** (`reflect_string` / `reflect_boolean`) that
    #    declares reflected attributes once and generates BOTH the snake_case
    #    getter/setter pair AND a `js_key => ruby_name` registry entry. A shared
    #    `__js_get__` / `__js_set__` consults that registry, so bridge property
    #    access needs no hand-written `case` arm. This keeps the Ruby accessor,
    #    the JS getter, and the JS setter from drifting apart (the same class of
    #    bug the `js_methods` macro prevents for `__js_call__`).
    #
    #        reflect_string :cx, :cy, :r
    #        reflect_string view_box: "viewBox", class_name: { attr: "class" }
    #        reflect_boolean :disabled, :required
    #
    #    Identifier defaults (override via a String or Hash value):
    #      - js_key (camelCase IDL name) = camelize(ruby_name)
    #      - attr   (content attribute)  = camelize(ruby_name)
    #      - String value overrides attr only:  text_anchor: "text-anchor"
    #      - Hash value overrides either:       tabindex: { js: "tabIndex" }
    module ReflectedAttributes
      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        def reflect_string(*names, **mapped)
          _reflect(:string, names, mapped)
        end

        def reflect_boolean(*names, **mapped)
          _reflect(:boolean, names, mapped)
        end

        # Merged `js_key => ruby_name` map across the class ancestry (memoized).
        # Recomputed lazily; `_reflect` invalidates the cache when called.
        def reflected_property_map
          @__reflected_map__ ||= begin
            inherited = superclass.respond_to?(:reflected_property_map) ? superclass.reflected_property_map : {}
            inherited.merge(@__reflected_props__ || {})
          end
        end

        private

        def _reflect(type, names, mapped)
          @__reflected_props__ ||= {}
          @__reflected_map__ = nil # invalidate memoized merge

          getter = type == :boolean ? :reflected_boolean : :reflected_string
          setter = type == :boolean ? :set_reflected_boolean : :set_reflected_string

          (names.map { |n| [n, nil] } + mapped.to_a).each do |ruby_name, override|
            attr, js = _resolve_identifiers(ruby_name, override)
            define_method(ruby_name) { __send__(getter, attr) }
            define_method(:"#{ruby_name}=") { |value| __send__(setter, attr, value) }
            @__reflected_props__[js] = ruby_name
          end
        end

        def _resolve_identifiers(ruby_name, override)
          default = _camelize(ruby_name)
          case override
          when nil
            [default, default]
          when String
            [override, default]
          when Hash
            [override[:attr] || default, override[:js] || default]
          else
            raise ArgumentError, "reflect_*: unsupported mapping for #{ruby_name.inspect}: #{override.inspect}"
          end
        end

        def _camelize(name)
          name.to_s.gsub(/_([a-z0-9])/) { ::Regexp.last_match(1).upcase }
        end
      end

      # Bridge property read: route reflected keys to their accessor (which a
      # subclass may have overridden with coercion), else up the super chain.
      def __js_get__(key)
        prop = self.class.reflected_property_map[key]
        return __send__(prop) if prop

        super
      end

      def __js_set__(key, value)
        prop = self.class.reflected_property_map[key]
        return __send__(:"#{prop}=", value) if prop

        super
      end

      private

      def reflected_string(name)
        get_attribute(name).to_s
      end

      def set_reflected_string(name, value)
        set_attribute(name, value.to_s)
      end

      def reflected_boolean(name)
        has_attribute?(name)
      end

      def set_reflected_boolean(name, value)
        if value
          set_attribute(name, "")
        elsif has_attribute?(name)
          remove_attribute(name)
        end
      end
    end
  end
end
