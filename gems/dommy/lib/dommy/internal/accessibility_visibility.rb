# frozen_string_literal: true

module Dommy
  module Internal
    # Whether an element is hidden from assistive technology.
    #
    # ARIA states one rule — `aria-hidden="true"`, or not rendered — and it was
    # written twice: the accessible name asked case-sensitively and looked only
    # at `display`/`visibility`, while the accessibility tree asked
    # case-insensitively and went through DomMatching (which also honours
    # `opacity`). `aria-hidden="TRUE"` was therefore hidden in the tree and
    # visible to the name.
    #
    # The `hidden` content attribute is the name computation's extra: HTML-AAM
    # keeps a `hidden` element out of a name from content, and it is also
    # `display: none` by the UA sheet, so the two agree wherever CSS is
    # available and this covers the case where it is not.
    module AccessibilityVisibility
      module_function

      def hidden?(element)
        return true if aria_hidden?(element)

        !DomMatching.visible?(element)
      end

      # The name-from-content variant. A node the author pointed at directly
      # with aria-labelledby is still named even when hidden — this only governs
      # the traversal INTO a subtree.
      def hidden_for_name?(element)
        return true if element.respond_to?(:has_attribute?) && element.has_attribute?("hidden")

        hidden?(element)
      end

      def aria_hidden?(element)
        element.get_attribute("aria-hidden").to_s.casecmp?("true")
      end

      # Everything above is the module; everything below is how.
      private_class_method :aria_hidden?
    end
  end
end
