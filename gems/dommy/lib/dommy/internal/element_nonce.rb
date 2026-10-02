# frozen_string_literal: true

module Dommy
  module Internal
    # HTMLOrSVGOrMathMLElement's `nonce`: the element's [[CryptographicNonce]]
    # (HTML, "Nonce attributes"). The nonce attribute sets it whenever it
    # changes — Element#attribute_change_steps forgets what the IDL setter
    # wrote, so the attribute's value counts again — and the IDL setter sets
    # it alone, leaving the attribute as it is. Not yet carried by cloning: a
    # copy reads its own attribute, not a nonce the setter wrote.
    module ElementNonce
      def nonce = @cryptographic_nonce || __internal_attribute_value__("nonce").to_s

      def nonce=(value)
        @cryptographic_nonce = value.to_s
      end
    end
  end
end
