# frozen_string_literal: true

module Dommy
  module Interaction
    # Synthesizes and dispatches the DOM event sequences a real browser fires
    # for user interactions, in the right order, so JS handlers (Stimulus
    # actions, React synthetic events, …) run exactly as they would in a
    # browser. Dispatch is Ruby-side; a JS-registered listener is invoked
    # synchronously through the bridge (CallableInvoker → __js_call__).
    module EventSynthesis
      module_function

      BUBBLES = {"bubbles" => true, "cancelable" => true, "composed" => true}.freeze

      # Full primary-button click: pointerdown → mousedown → focus → pointerup →
      # mouseup → click. Returns true when the `click` default was prevented (the
      # caller suppresses any follow-on navigation / submission).
      def click(element)
        dispatch(element, Dommy::PointerEvent.new("pointerdown", mouse_init))
        dispatch(element, Dommy::MouseEvent.new("mousedown", mouse_init))
        focus(element)
        dispatch(element, Dommy::PointerEvent.new("pointerup", mouse_init))
        dispatch(element, Dommy::MouseEvent.new("mouseup", mouse_init))
        event = Dommy::MouseEvent.new("click", mouse_init)
        element.dispatch_event(event)
        event.default_prevented?
      end

      def focus(element)
        dispatch(element, Dommy::FocusEvent.new("focus", "composed" => true))
        dispatch(element, Dommy::FocusEvent.new("focusin", BUBBLES))
      end

      def blur(element)
        dispatch(element, Dommy::FocusEvent.new("blur", "composed" => true))
        dispatch(element, Dommy::FocusEvent.new("focusout", BUBBLES))
      end

      def input(element, data = nil)
        dispatch(element, Dommy::InputEvent.new("input", BUBBLES.merge("data" => data, "inputType" => "insertText")))
      end

      def change(element)
        dispatch(element, Dommy::Event.new("change", "bubbles" => true))
      end

      def dispatch(element, event)
        element.dispatch_event(event)
      end

      def mouse_init
        BUBBLES.merge("button" => 0, "clientX" => 0, "clientY" => 0)
      end
    end
  end
end
