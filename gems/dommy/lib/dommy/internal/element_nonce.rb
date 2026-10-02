# frozen_string_literal: true

module Dommy
  module Internal
    # HTMLOrSVGOrMathMLElement's `nonce`: the element's [[CryptographicNonce]]
    # (HTML, "Nonce attributes"). The nonce attribute sets it whenever it
    # changes — Element#attribute_change_steps forgets what the IDL setter
    # wrote, so the attribute's value counts again — and the IDL setter sets
    # it alone, leaving the attribute as it is. Its cloning steps give a copy
    # the nonce the setter wrote.
    module ElementNonce
      def nonce = @cryptographic_nonce || __internal_attribute_value__("nonce").to_s

      def nonce=(value)
        @cryptographic_nonce = value.to_s
      end

      def __internal_cloning_state__
        merge_cloning_state(super, @cryptographic_nonce.nil? ? {} : {nonce: @cryptographic_nonce})
      end

      def __internal_apply_cloning_state__(state)
        super
        @cryptographic_nonce = state[:nonce] if state.key?(:nonce)
      end
    end
  end
end
