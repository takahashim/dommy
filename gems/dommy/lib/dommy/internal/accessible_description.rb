# frozen_string_literal: true

module Dommy
  module Internal
    # Computes an element's WAI-ARIA *accessible description* — what WPT's
    # `test_driver.get_computed_label`'s description counterpart returns. The
    # description sources, in precedence order, are `aria-describedby`,
    # `aria-description`, then `title`. It reuses the accessible-name machinery
    # to resolve the describedby IDREF list (each referenced element contributes
    # its accessible NAME).
    #
    # The one subtlety: `title` provides the accessible name when nothing else
    # does, and provides the description otherwise — it must not be counted as
    # both. So title is used as the description only when it was NOT already
    # consumed as the element's name.
    module AccessibleDescription
      module_function

      # The accessible description string ("" when none).
      def compute(element)
        return "" unless element.respond_to?(:__dommy_backend_node__)

        described = AccessibleName.referenced_names(element, "aria-describedby")
        return described.strip if described

        attr = element.get_attribute("aria-description").to_s
        return attr.strip unless attr.strip.empty?

        title = element.get_attribute("title").to_s.strip
        return "" if title.empty?
        # title already serves as the accessible name — don't double-count it.
        return "" if AccessibleName.compute(element) == title

        title
      end
    end
  end
end
