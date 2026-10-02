# frozen_string_literal: true

module Dommy
  module Internal
    # CSSOM's ElementCSSInlineStyle mixin: the `style` declaration block over
    # the element's style attribute, which HTMLElement, SVGElement and
    # MathMLElement include and a plain Element does not. `el.style = text`
    # is [PutForwards=cssText].
    #
    # Host contract: a class that includes Internal::ReflectedAttributes
    # first, whose bridge registry the accessor is declared in.
    module ElementCSSInlineStyle
      def self.included(base)
        base.js_accessor :style
      end

      def style
        @style ||= StyleDeclaration.new(self)
      end

      def style=(value)
        style.css_text = value.nil? ? "" : value.to_s
      end
    end
  end
end
