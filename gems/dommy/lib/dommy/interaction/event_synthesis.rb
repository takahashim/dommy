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

      # Run the element's focusing steps (Element#focus): moves
      # document.activeElement and fires blur/focusout on the previously
      # focused element plus focus/focusin here — a no-op when the element
      # already holds focus, like a real browser.
      def focus(element)
        element.focus if element.respond_to?(:focus)
        nil
      end

      def blur(element)
        element.blur if element.respond_to?(:blur)
        nil
      end

      def input(element, data = nil, input_type = "insertText")
        dispatch(element, Dommy::InputEvent.new("input", BUBBLES.merge("data" => data, "inputType" => input_type)))
      end

      def change(element)
        dispatch(element, Dommy::Event.new("change", "bubbles" => true))
      end

      def dispatch(element, event)
        element.dispatch_event(event)
      end

      # Named keys for Driver#send_keys, mapped to their KeyboardEvent
      # key/code pairs. Aliases (:up for :arrow_up, …) match Capybara's.
      NAMED_KEYS = {
        enter: ["Enter", "Enter"],
        tab: ["Tab", "Tab"],
        escape: ["Escape", "Escape"],
        space: [" ", "Space"],
        backspace: ["Backspace", "Backspace"],
        delete: ["Delete", "Delete"],
        arrow_up: ["ArrowUp", "ArrowUp"],
        arrow_down: ["ArrowDown", "ArrowDown"],
        arrow_left: ["ArrowLeft", "ArrowLeft"],
        arrow_right: ["ArrowRight", "ArrowRight"],
        up: ["ArrowUp", "ArrowUp"],
        down: ["ArrowDown", "ArrowDown"],
        left: ["ArrowLeft", "ArrowLeft"],
        right: ["ArrowRight", "ArrowRight"],
        home: ["Home", "Home"],
        end: ["End", "End"],
        page_up: ["PageUp", "PageUp"],
        page_down: ["PageDown", "PageDown"],
      }.freeze

      # keydown is cancelable: a prevented keydown suppresses the key's
      # default action (typing, implicit submission). Returns whether it was
      # prevented, like #click.
      def keydown(element, key, code)
        event = Dommy::KeyboardEvent.new("keydown", key_init(key, code))
        element.dispatch_event(event)
        event.default_prevented?
      end

      # keypress fires only for keys that produce a character (legacy but
      # still widely handled). Also cancelable; a prevented keypress
      # suppresses the character insertion.
      def keypress(element, key, code)
        event = Dommy::KeyboardEvent.new("keypress", key_init(key, code))
        element.dispatch_event(event)
        event.default_prevented?
      end

      def keyup(element, key, code)
        dispatch(element, Dommy::KeyboardEvent.new("keyup", key_init(key, code)))
      end

      # beforeinput precedes the value mutation and is cancelable (the input
      # event that follows the mutation is not).
      def beforeinput(element, data, input_type)
        event = Dommy::InputEvent.new(
          "beforeinput", BUBBLES.merge("data" => data, "inputType" => input_type)
        )
        element.dispatch_event(event)
        event.default_prevented?
      end

      # The KeyboardEvent code for a typed character ("a" -> "KeyA").
      # Best-effort: unknown characters get an empty code, like a real
      # browser does for keys it can't map to a physical position.
      def char_code(char)
        case char
        when /\A[a-zA-Z]\z/ then "Key#{char.upcase}"
        when /\A[0-9]\z/ then "Digit#{char}"
        when " " then "Space"
        else ""
        end
      end

      def key_init(key, code)
        BUBBLES.merge("key" => key, "code" => code)
      end

      def mouse_init
        BUBBLES.merge("button" => 0, "clientX" => 0, "clientY" => 0)
      end
    end
  end
end
