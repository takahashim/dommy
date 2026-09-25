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
        # Dispatch runs the click's activation behavior itself (hyperlink
        # navigation, form submission, the checkbox toggle plus input/change), so
        # a synthetic click takes exactly the same path as `element.click()`.
        element.dispatch_event(event)
        event.default_prevented?
      end

      # A secondary-button (right) click: pointerdown → mousedown → pointerup →
      # mouseup → contextmenu. `button: 2` marks the secondary button, which is
      # what a `contextmenu` handler checks. No click event fires for a right
      # click, so no activation behavior runs. Returns whether contextmenu was
      # prevented.
      def right_click(element)
        secondary = mouse_init.merge("button" => 2)
        dispatch(element, Dommy::PointerEvent.new("pointerdown", secondary))
        dispatch(element, Dommy::MouseEvent.new("mousedown", secondary))
        focus(element)
        dispatch(element, Dommy::PointerEvent.new("pointerup", secondary))
        dispatch(element, Dommy::MouseEvent.new("mouseup", secondary))
        event = Dommy::MouseEvent.new("contextmenu", secondary)
        element.dispatch_event(event)
        event.default_prevented?
      end

      # A double click: the full primary sequence twice, ending in `dblclick`
      # (after the second `click`). Each click runs its own activation behavior,
      # matching a browser where two native clicks fire two click events.
      def double_click(element)
        click(element)
        event = Dommy::MouseEvent.new("click", mouse_init.merge("detail" => 2))
        element.dispatch_event(event)
        dbl = Dommy::MouseEvent.new("dblclick", mouse_init.merge("detail" => 2))
        element.dispatch_event(dbl)
        dbl.default_prevented?
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

      # Move the pointer onto `element`: mouseover (bubbling) then mouseenter
      # (non-bubbling) on the element, and — for each ancestor it newly enters —
      # mouseenter, in outer-to-inner order, before the element's own enter. A
      # browser fires mouseover on every element the pointer ends over (bubbling
      # from the target), and mouseenter only where it newly entered. `from` is
      # the previously hovered element (nil when the pointer came from outside
      # the document), used to compute which ancestors are newly entered.
      def hover(element, from: nil)
        entered = ancestors_entered(element, from)
        dispatch(element, Dommy::MouseEvent.new("mouseover", mouse_init))
        entered.each { |ancestor| dispatch(ancestor, Dommy::MouseEvent.new("mouseenter", enter_leave_init)) }
        dispatch(element, Dommy::MouseEvent.new("mouseenter", enter_leave_init))
        nil
      end

      # The pointer left `element` for `to` (nil when it left the document):
      # mouseout (bubbling) then mouseleave (non-bubbling) on the element, and
      # mouseleave for each ancestor no longer under the pointer, inner-to-outer.
      def unhover(element, to: nil)
        left = ancestors_left(element, to)
        dispatch(element, Dommy::MouseEvent.new("mouseout", mouse_init))
        dispatch(element, Dommy::MouseEvent.new("mouseleave", enter_leave_init))
        left.each { |ancestor| dispatch(ancestor, Dommy::MouseEvent.new("mouseleave", enter_leave_init)) }
        nil
      end

      # The ancestors of `element` that `from` is NOT inside — the ones the
      # pointer newly entered — ordered outer-to-inner.
      def ancestors_entered(element, from)
        from_chain = ancestor_chain(from)
        ancestor_chain(element).reject { |a| from_chain.include?(a) }.reverse
      end

      # The ancestors of `element` that `to` does not sit inside — the ones the
      # pointer left — ordered inner-to-outer.
      def ancestors_left(element, to)
        to_chain = ancestor_chain(to)
        ancestor_chain(element).reject { |a| to_chain.include?(a) }
      end

      def ancestor_chain(element)
        chain = []
        node = element&.parent_node
        while node.respond_to?(:tag_name)
          chain << node
          node = node.parent_node
        end
        chain
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
      def keydown(element, key, code, extra = nil)
        event = Dommy::KeyboardEvent.new("keydown", key_init(key, code, extra))
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

      def keyup(element, key, code, extra = nil)
        dispatch(element, Dommy::KeyboardEvent.new("keyup", key_init(key, code, extra)))
      end

      # IME composition events. compositionstart is cancelable per spec;
      # update / end are not.
      def compositionstart(element, data = "")
        dispatch(element, Dommy::CompositionEvent.new("compositionstart", BUBBLES.merge("data" => data)))
      end

      def compositionupdate(element, data)
        dispatch(element, Dommy::CompositionEvent.new("compositionupdate",
          "bubbles" => true, "composed" => true, "data" => data))
      end

      def compositionend(element, data)
        dispatch(element, Dommy::CompositionEvent.new("compositionend",
          "bubbles" => true, "composed" => true, "data" => data))
      end

      # The input pair during composition: beforeinput then input, both with
      # inputType insertCompositionText and isComposing true. Unlike ordinary
      # typing, the composition beforeinput is NOT cancelable (spec).
      def composition_input(element, data)
        init = {"bubbles" => true, "composed" => true,
                "data" => data, "inputType" => "insertCompositionText", "isComposing" => true}
        dispatch(element, Dommy::InputEvent.new("beforeinput", init))
        dispatch(element, Dommy::InputEvent.new("input", init))
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

      def key_init(key, code, extra = nil)
        init = BUBBLES.merge("key" => key, "code" => code)
        extra ? init.merge(extra) : init
      end

      def mouse_init
        BUBBLES.merge("button" => 0, "clientX" => 0, "clientY" => 0)
      end

      # mouseenter / mouseleave do NOT bubble (they fire once per element whose
      # boundary was crossed), unlike mouseover / mouseout which do.
      def enter_leave_init
        {"bubbles" => false, "cancelable" => false, "composed" => true,
         "button" => 0, "clientX" => 0, "clientY" => 0}
      end
    end
  end
end
