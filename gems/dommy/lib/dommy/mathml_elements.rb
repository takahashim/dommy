# frozen_string_literal: true

module Dommy
  # `MathMLElement` (MathML Core) — every element in the MathML namespace.
  # It has no attributes of its own beyond the HTMLOrSVGOrMathMLElement mixin
  # (dataset, nonce, autofocus, tabIndex, focus, blur), which is what sets it
  # apart from an Element in any other namespace.
  class MathMLElement < Element
    include Internal::ReflectedAttributes
    include Internal::HTMLOrSVGOrMathMLElement
  end
end
