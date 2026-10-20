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
          file-selector-button grammar-error spelling-error target-text view-transition
        ].freeze

        def initialize(element, pseudo_element: nil)
          @element = element
          @pseudo_element = pseudo_element
        end

        def get_property_value(name)
          # Custom properties are case-sensitive; everything else is ASCII
          # case-insensitive, and a -webkit- legacy alias reads its property.
          styles[Dommy::Internal::CSS::Parser.property_name(name)].to_s
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

        # The declaration is read-only: writing one of its properties (or
        # cssText) is a NoModificationAllowedError. Any other name is a plain
        # expando.
        def __js_set__(key, _value)
          kebab = camel_to_kebab(key)
          raise_read_only if key == "cssText" || css_property?(kebab)

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

        def css_property?(name)
          PropertyRegistry::PROPERTIES.key?(name) || PropertyRegistry::BOX_SHORTHANDS.key?(name) ||
            Cascade.computed_style(@element).key?(name)
        end

        # CSS2's pseudo-elements, which a single colon still names.
        LEGACY_PSEUDO_ELEMENTS = %w[before after first-line first-letter].freeze

        # Pseudo-elements that take an argument (`::highlight(name)`).
        FUNCTIONAL_PSEUDO_ELEMENTS = %w[
          highlight view-transition-group view-transition-image-pair view-transition-old view-transition-new
        ].freeze

        # CSSOM getComputedStyle step 4: a pseudoElt that does not start with a
        # colon is ignored (the element's own style); one that does names a
        # pseudo-element — `::name`, or `:name` for the CSS2 four — and any
        # other, an unknown or a `:marker`, gets an empty declaration.
        def styles
          return Cascade.computed_style(@element) unless @pseudo_element

          text = @pseudo_element.to_s
          return Cascade.computed_style(@element) unless text.start_with?(":")

          name = text.delete_prefix("::")
          name = text.delete_prefix(":") if name == text && LEGACY_PSEUDO_ELEMENTS.include?(text.delete_prefix(":").downcase)
          return EMPTY if name == text

          # The cascade indexes a functional pseudo-element by its name; the
          # argument selects nothing further here.
          base = name.downcase
          functional = base.match(/\A([a-z-]+)\(.+\)\z/)
          base = functional[1] if functional
          known = functional ? FUNCTIONAL_PSEUDO_ELEMENTS.include?(base) : KNOWN_PSEUDO_ELEMENTS.include?(base)
          return EMPTY unless known

          Cascade.computed_style(@element, pseudo_element: "::#{base}")
        end

        # The property a camel-cased (or snake_case) attribute name stands for,
        # as on element.style: `cssFloat` is `float`, a webkit-cased name the
        # -webkit- property and so its legacy alias's (`webkitFilter` is
        # `filter`). A custom property is its own name.
        def camel_to_kebab(name)
          text = name.to_s
          return text if text.start_with?("--")
          return "float" if text == "cssFloat" || text == "css_float"

          kebab = text.tr("_", "-").gsub(/([A-Z])/) { "-#{Regexp.last_match(1).downcase}" }
          kebab = "-#{kebab}" if kebab.start_with?("webkit-")
          Dommy::Internal::CSS::Parser.property_name(kebab)
        end

        def raise_read_only
          raise DOMException::NoModificationAllowedError,
            "Cannot modify a computed style declaration"
        end
      end
    end
  end
end
