# frozen_string_literal: true

require "securerandom"

module Dommy
  # `Crypto` — mirror of `window.crypto`. Exposes `randomUUID()` and
  # `getRandomValues(typedArray)` backed by Ruby's SecureRandom.
  # SubtleCrypto (`crypto.subtle`) is out of scope.
  #
  # Spec: https://w3c.github.io/webcrypto/
  class Crypto
    # JS: crypto.randomUUID() → version-4 UUID string.
    def random_uuid
      SecureRandom.uuid
    end

    alias randomUUID random_uuid

    # JS: crypto.getRandomValues(typedArray) — fills the supplied
    # buffer in place and returns it. Dommy doesn't model typed
    # arrays specifically; any Array-like object that responds to
    # `[]=` and `size` works (or a `Dommy::Blob`-like wrapper that
    # exposes a backing array).
    def get_random_values(typed_array)
      return typed_array unless typed_array.respond_to?(:size) && typed_array.respond_to?(:[]=)

      bytes = SecureRandom.bytes(typed_array.size).bytes
      typed_array.size.times { |i| typed_array[i] = bytes[i] }
      typed_array
    end

    alias getRandomValues get_random_values

    def __js_get__(key)
      case key
      # SubtleCrypto not implemented
      when "subtle"
        nil
      end
    end

    def __js_call__(method, args)
      case method
      when "randomUUID"
        random_uuid
      when "getRandomValues"
        get_random_values(args[0])
      end
    end
  end
end
