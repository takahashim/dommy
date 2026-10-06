# frozen_string_literal: true

module Dommy
  # A value serialized by HTML's StructuredSerialize (WithTransfer), held until
  # it is deserialized where the message is delivered. Ruby never looks inside:
  # the realm that serialized it is the one that knows how to deserialize it.
  #
  # Spec: https://html.spec.whatwg.org/multipage/structured-data.html
  class SerializedValue
    # StructuredDeserialize: a fresh copy of the value.
    def deserialize = deserialize_with_transfer.first

    # StructuredDeserializeWithTransfer: `[value, transferred MessagePorts]`.
    # Raises DOMException::DataCloneError when the value cannot be rebuilt
    # (the caller fires `messageerror` then).
    def deserialize_with_transfer
      raise NotImplementedError
    end
  end

  # A value posted from Ruby (`window.post_message(hash)`): serialized as a
  # deep clone, deserialized as another one.
  class RubySerializedValue < SerializedValue
    def initialize(value)
      super()
      @snapshot = Dommy.structured_clone(value)
    end

    def deserialize_with_transfer = [Dommy.structured_clone(@snapshot), []]
  end

  # StructuredSerialize: a value serialized by the JS realm passes through as
  # it is; a Ruby value is cloned.
  def self.structured_serialize(value)
    value.is_a?(SerializedValue) ? value : RubySerializedValue.new(value)
  end

  # StructuredDeserialize of what structured_serialize returned (nil — an entry
  # with no serialized state — stays nil).
  def self.structured_deserialize(serialized)
    return nil if serialized.nil?

    serialized.is_a?(SerializedValue) ? serialized.deserialize : structured_clone(serialized)
  end
end
