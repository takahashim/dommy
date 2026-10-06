# frozen_string_literal: true

module Dommy
  module Js
    # A message the JS realm serialized (host_runtime.js
    # structuredSerializeWithTransfer), referenced by its id there. The record
    # itself — cycles, BigInts, lone surrogates, a transferred ArrayBuffer — only
    # makes sense in the realm, so deserializing asks the realm to do it.
    class SerializedRecord < Dommy::SerializedValue
      attr_reader :id

      def initialize(bridge, id)
        super()
        @bridge = bridge
        @id = id
      end

      def deserialize_with_transfer
        result = @bridge.deserialize_record(@id)
        raise DOMException::DataCloneError, result["error"].to_s if result.key?("error")

        [result["value"], Array(result["ports"])]
      end

      # Forget the record JS-side, once nothing will deserialize it again.
      def release
        @bridge.release_record(@id)
        nil
      end
    end
  end
end
