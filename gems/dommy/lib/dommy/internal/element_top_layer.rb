# frozen_string_literal: true

module Dommy
  module Internal
    # Putting an element in the top layer: the fullscreen request, which
    # every element has. Nothing renders it — what it produces is the state a
    # script reads back. (The popover, HTMLElement's alone, is
    # Internal::ElementPopover.)
    #
    # Host contract: @document responding to
    # #__internal_set_fullscreen_element__ / #default_view.
    module ElementTopLayer
      def request_fullscreen
        @document.__internal_set_fullscreen_element__(self)
        PromiseValue.resolve(@document.default_view, nil)
      end
    end
  end
end
