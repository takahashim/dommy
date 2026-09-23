# frozen_string_literal: true

module Dommy
  module Internal
    module CSS
      # The read-only CSSStyleDeclaration that getComputedStyle returns.
      # CSSOM's "live object" behavior is approximated by recomputing lazily:
      # every read goes through Cascade.computed_style, whose per-generation
      # memo makes repeated reads cheap while DOM mutations show up on the
      # next read. ::before/::after expose cascaded computed declarations even
      # though Dommy renders no generated boxes.
      class ComputedStyleDeclaration
        EMPTY = {}.freeze

        # Pseudo-elements getComputedStyle exposes a cascaded computed
        # declaration for (no box generation, just the cascade). Unknown
        # pseudo-elements yield an empty declaration, as browsers do.
        KNOWN_PSEUDO_ELEMENTS = %w[
          before after first-line first-letter marker selection placeholder backdrop
        ].freeze

        def initialize(element, pseudo_element: nil)
          @element = element
          @pseudo_element = pseudo_element
        end

        def get_property_value(name)
          key = name.to_s
          # Custom properties are case-sensitive; everything else isn't.
          key = key.downcase unless key.start_with?("--")
          styles[key].to_s
        end

        def [](name)
          get_property_value(name)
        end

        def length
          styles.size
        end

        def item(index)
          styles.keys[index].to_s
        end

        def css_text
          styles.map { |name, value| "#{name}: #{value};" }.join(" ")
        end

        def to_h
          styles.dup
        end

        def set_property(*, **)
          raise_read_only
        end

        def remove_property(*)
          raise_read_only
        end

        # --- JS bridge ---

        def __js_get__(key)
          case key
          when "cssText" then css_text
          when "length" then length
          when "parentRule" then nil
          else
            # An unset/unknown property reads as "" per CSSStyleDeclaration
            # (a detached element's whole declaration is empty), not undefined.
            styles[camel_to_kebab(key)].to_s
          end
        end

        def __js_set__(_key, _value)
          Bridge::UNHANDLED
        end

        include Bridge::Methods
        js_methods %w[getPropertyValue getPropertyPriority item setProperty removeProperty]
        def __js_call__(method, args)
          case method
          when "getPropertyValue"
            get_property_value(args[0])
          when "getPropertyPriority"
            ""
          when "item"
            item(args[0].to_i)
          when "setProperty", "removeProperty"
            raise_read_only
          end
        end

        # Ruby-side property readers, e.g. `computed.background_color` or
        # `computed.backgroundColor`.
        #
        # A write to one of them is the CSSOM error — the declaration is
        # read-only — but only to one of them: `computed.anything = 1` used to
        # raise NoModificationAllowedError for every name ending in "=",
        # including typos and the `x=` methods a library might add, where a
        # plain NoMethodError is the truth.
        def method_missing(name, *args)
          property = property_for(name)
          raise_read_only if property && setter?(name)
          return super if property.nil? || !args.empty?

          styles[property].to_s
        end

        def respond_to_missing?(name, include_private = false)
          !property_for(name).nil? || super
        end

        private

        # The CSS property `name` reads or writes, or nil when it names none.
        def property_for(name)
          text = name.to_s
          key = camel_to_kebab(setter?(name) ? text.delete_suffix("=") : text)
          key if styles.key?(key)
        end

        def setter?(name) = name.to_s.end_with?("=")

        def styles
          if @pseudo_element
            name = @pseudo_element.to_s.delete_prefix("::").delete_prefix(":")
            return EMPTY unless KNOWN_PSEUDO_ELEMENTS.include?(name)
          end

          Cascade.computed_style(@element, pseudo_element: @pseudo_element)
        end

        def camel_to_kebab(name)
          name.to_s.tr("_", "-").gsub(/([A-Z])/) { "-#{Regexp.last_match(1).downcase}" }
        end

        def raise_read_only
          raise DOMException::NoModificationAllowedError,
            "Cannot modify a computed style declaration"
        end
      end
    end
  end
end
