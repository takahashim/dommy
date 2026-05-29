# frozen_string_literal: true

module Dommy
  module Internal
    # IDL-attribute reflection helpers for `HTMLElement` and `SVGElement`
    # subclasses. Each helper delegates to the host element's standard
    # attribute API (`get_attribute` / `set_attribute` / `has_attribute?`
    # / `remove_attribute`), so case-sensitivity is naturally inherited
    # from the host element's namespace — HTML lowercases, SVG keeps
    # the spec name (`viewBox`).
    #
    # Two reflection styles:
    #
    # - **String**: the property mirrors the attribute value verbatim.
    #   Missing → `""` (not nil), so subclasses don't need defensive
    #   `.to_s`.
    #
    # - **Boolean**: the property is true iff the attribute is present
    #   (value ignored). Setting to true writes an empty string; setting
    #   to false removes the attribute.
    module ReflectedAttributes
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
