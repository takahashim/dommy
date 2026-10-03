# frozen_string_literal: true

module Dommy
  module Internal
    # HTML's HTMLOrSVGOrMathMLElement mixin: what HTMLElement, SVGElement and
    # MathMLElement have and a plain Element — one in no namespace, or in any
    # other — does not. `dataset`, `nonce`, `autofocus`, `tabIndex`, `focus()`
    # and `blur()`, here once rather than on Element, where they answered for
    # every element.
    #
    # Host contract: a class that includes Internal::ReflectedAttributes
    # first, whose reflection DSL the attributes are declared with.
    module HTMLOrSVGOrMathMLElement
      include ElementNonce

      def self.included(base)
        base.js_accessor :nonce
        base.js_readable :dataset
        base.reflect_boolean :autofocus
        base.reflect_long_setter tab_index: { attr: "tabindex", js: "tabIndex" }
      end

      JS_METHOD_NAMES = %w[focus blur].freeze

      def dataset
        @dataset ||= DatasetMap.new(self)
      end

      def __js_call__(method, args)
        case method
        when "focus" then focus
        when "blur" then blur
        else super
        end
      end

      # `tabIndex` (HTML §6.6.3): the tabindex attribute parsed as an
      # integer, else the element's default — 0 for the elements a user can
      # usually focus, which each interface names (#default_tab_index), and
      # -1 for the rest.
      def tab_index = parsed_long_attribute("tabindex") || default_tab_index

      def default_tab_index = -1

      # `focus()` — the HTML focusing steps, minus layout: Dommy treats any
      # such element as focusable (except a disabled form control), then
      # updates document.activeElement AND fires the focus-change events a
      # real browser would — blur/focusout on the previously focused element,
      # then focus/focusin here, with relatedTarget linking the two. JS
      # calling `input.focus()` therefore triggers the same focus handlers a
      # user's click/tab would; already-focused and disabled targets are
      # no-ops.
      def focus
        return nil if disabled_form_control?
        return nil if @document.__internal_focused_element__.equal?(self)

        previous = @document.__internal_focused_element__
        fire_focus_out(previous, self) if previous
        @document.__internal_set_active_element__(self)
        dispatch_event(Dommy::FocusEvent.new("focus", "composed" => true, "relatedTarget" => previous))
        dispatch_event(Dommy::FocusEvent.new("focusin",
          "bubbles" => true, "composed" => true, "relatedTarget" => previous))
        nil
      end

      def blur
        return nil unless @document.__internal_focused_element__.equal?(self)

        @document.__internal_set_active_element__(nil)
        fire_focus_out(self, nil)
        nil
      end
    end
  end
end
