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
        when "focus" then focus(args[0])
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

      # `focus(options)` — HTML's focusing steps for this element
      # (Internal::Focusability): a focusable area takes the focus; a shadow
      # host that delegates focus hands it to its focus delegate; anything
      # else (a plain div, a disabled or inert control, a disconnected or
      # display:none element) is left alone, as is the element already
      # focused. Moving the focus fires blur and focusout at the element that
      # loses it, then focus and focusin here. Nothing scrolls.
      #
      # FocusOptions' `focusVisible` says whether the focus is indicated
      # (`:focus-visible`); without it, the heuristics in
      # Internal::DocumentInteractionState decide.
      def focus(options = nil)
        visible = focus_visible_option(options)
        document = owner_document
        document.__internal_with_focus_type__(:script, focus_visible: visible) do
          Focusability.run_focusing_steps(self)
        end
        document.__internal_indicate_focus__ if visible == true && document.__internal_focused_element__.equal?(self)
        nil
      end

      # FocusOptions' `focusVisible` (a boolean with no default), nil when the
      # dictionary has none.
      def focus_visible_option(options)
        return nil unless options.is_a?(Hash)

        key = ["focusVisible", :focusVisible].find { |k| options.key?(k) }
        return nil if key.nil? || options[key].equal?(Bridge::UNDEFINED)

        WebIDL.boolean(options[key])
      end
      private :focus_visible_option

      # `blur()` — HTML's unfocusing steps: the focused element gives the
      # focus back to the viewport.
      def blur
        Focusability.run_unfocusing_steps(self)
        nil
      end
    end
  end
end
