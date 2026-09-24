# frozen_string_literal: true

module Dommy
  module Internal
    module RenderedText
      # The computed properties the collection steps read from one element.
      #
      # An empty computed style (no CSS layer to ask) falls back to each
      # property's initial value. `display` alone has no usable one — `inline`
      # would make every <div> inline — so it is nil there, and the caller
      # falls back to the element's UA-default box instead.
      ComputedBox = Data.define(:display, :visibility, :white_space, :text_transform) do
        def self.from(style)
          new(
            display: value_of(style, "display"),
            visibility: value_of(style, "visibility") || "visible",
            white_space: value_of(style, "white-space") || "normal",
            text_transform: value_of(style, "text-transform") || "none"
          )
        end

        def self.value_of(style, property)
          value = style[property].to_s
          value unless value.empty?
        end
        private_class_method :value_of

        def visible? = visibility == "visible"

        def none? = display == "none"

        def contents? = display == "contents"

        # Inline-level, counting an unknown display as the inline default.
        def inline_level? = display.nil? || display.start_with?("inline")
      end
    end
  end
end
