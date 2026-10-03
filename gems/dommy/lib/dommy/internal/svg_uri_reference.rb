# frozen_string_literal: true

module Dommy
  module Internal
    # SVG 2's SVGURIReference mixin: the `href` of the SVG elements that
    # refer to another resource (a, use, image, pattern, the gradients,
    # filter, textPath, feImage, mpath). It reads the `href` attribute, or
    # the deprecated `xlink:href` when there is no `href`, which older SVG
    # still writes; the setter writes whichever of the two is there, `href`
    # when neither is.
    #
    # Dommy answers the string SVG's animated values reduce to, here as for
    # every other SVG attribute, rather than an SVGAnimatedString.
    #
    # Host contract: a class that includes Internal::ReflectedAttributes
    # first, whose bridge registry the accessor is declared in.
    module SVGURIReference
      def self.included(base)
        base.js_accessor :href
      end

      def href = __internal_attribute_value__("href") || get_attribute_ns(Namespaces::XLINK, "href") || ""

      def href=(value)
        if __internal_attribute_value__("href").nil? && !get_attribute_ns(Namespaces::XLINK, "href").nil?
          set_attribute_ns(Namespaces::XLINK, "xlink:href", value.to_s)
        else
          __internal_set_attribute_value__("href", value.to_s)
        end
      end
    end
  end
end
