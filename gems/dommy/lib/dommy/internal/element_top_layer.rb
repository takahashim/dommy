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
      # `requestFullscreen()`: a transient activation-consuming API — without
      # transient activation the request fails (a `fullscreenerror` at the
      # element and a promise rejected with a TypeError); with it, the
      # activation is consumed and the element becomes the fullscreen
      # element.
      def request_fullscreen
        window = @document.default_view
        unless window.respond_to?(:__internal_transient_activation__?) && window.__internal_transient_activation__?
          target = self
          window.scheduler.set_timeout(proc { target.dispatch_event(Event.new("fullscreenerror", "bubbles" => true,
            "composed" => true).__internal_mark_trusted__) }, 0) if window.respond_to?(:scheduler)
          return PromiseValue.reject(window, Bridge::TypeError.new("Fullscreen request denied: no transient activation"))
        end

        window.__internal_consume_user_activation__
        @document.__internal_set_fullscreen_element__(self)
        PromiseValue.resolve(window, nil)
      end
    end
  end
end
