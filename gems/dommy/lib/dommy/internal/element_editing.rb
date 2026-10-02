# frozen_string_literal: true

module Dommy
  module Internal
    # Whether an element is editable through contenteditable or designMode
    # (HTML §6.8.1): an editing host — an element whose contenteditable is
    # true or plaintext-only, or a document in design mode — and what it
    # contains, unless an element in between turns editing off. `isContentEditable`
    # and `:read-write` both ask this.
    module ElementEditing
      module_function

      # The contenteditable attribute's state, matched ASCII
      # case-insensitively: :true for "true" or "", :plaintext_only, :false,
      # or :inherit for any other value or none.
      def state(element)
        case element.__internal_attribute_value__("contenteditable")&.downcase(:ascii)
        when "true", "" then :true
        when "plaintext-only" then :plaintext_only
        when "false" then :false
        else :inherit
        end
      end

      # Whether the element is an editing host or editable: the nearest
      # contenteditable that is not inherit decides, and with none the
      # design mode of the document it is in.
      def editable?(element)
        node = element
        while node
          case state(node)
          when :true, :plaintext_only then return true
          when :false then return false
          end
          node = node.parent_element
        end
        element.is_connected? && element.owner_document.__internal_design_mode__?
      end
    end
  end
end
