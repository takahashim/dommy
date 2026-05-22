# frozen_string_literal: true

require "securerandom"
require "digest"
require "openssl"

module Dommy
  # `Crypto` — mirror of `window.crypto`. Exposes `randomUUID()`,
  # `getRandomValues(typedArray)`, and a minimal `subtle` surface
  # (digest only, sufficient for most test fixtures).
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

    def subtle
      @subtle ||= SubtleCrypto.new
    end

    def __js_get__(key)
      case key
      when "subtle"
        subtle
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

  # `SubtleCrypto` — `window.crypto.subtle`. Currently covers `digest`
  # (SHA-1 / SHA-256 / SHA-384 / SHA-512), which is by far the most
  # commonly used operation in test contexts. Encrypt / decrypt /
  # sign / verify / key generation are out of scope; tests that
  # need them should mock `crypto.subtle` directly.
  #
  # Returned values are byte arrays — real `SubtleCrypto.digest`
  # resolves to an `ArrayBuffer`; we expose the equivalent Ruby
  # byte array so callers can convert as needed.
  class SubtleCrypto
    ALGORITHMS = {
      "SHA-1" => -> (data) { Digest::SHA1.digest(data) },
      "SHA-256" => -> (data) { Digest::SHA256.digest(data) },
      "SHA-384" => -> (data) { Digest::SHA384.digest(data) },
      "SHA-512" => -> (data) { Digest::SHA512.digest(data) }
    }.freeze

    def digest(algorithm, data)
      name = algorithm_name(algorithm)
      hasher = ALGORITHMS[name]
      raise ArgumentError, "unsupported algorithm: #{name}" unless hasher

      hasher.call(coerce_bytes(data)).bytes
    end

    # Generate a fresh HMAC key. `algorithm` is either the string
    # `"HMAC"` (defaults to SHA-256) or `{name: "HMAC", hash: "SHA-256"}`.
    def generate_key(algorithm, _extractable = true, _usages = nil)
      hash = hmac_hash_from(algorithm)
      key_bytes = SecureRandom.bytes(openssl_digest_size(hash))
      CryptoKey.new(:secret, "HMAC", hash, key_bytes, usages: ["sign", "verify"])
    end

    alias generateKey generate_key

    # Import a raw HMAC key (only `format: "raw"` supported).
    def import_key(format, key_data, algorithm, _extractable = true, usages = nil)
      raise ArgumentError, "only raw format supported" unless format.to_s == "raw"

      hash = hmac_hash_from(algorithm)
      bytes = coerce_bytes(key_data)
      CryptoKey.new(:secret, "HMAC", hash, bytes, usages: usages || ["sign", "verify"])
    end

    alias importKey import_key

    # HMAC sign — returns the MAC as a byte array.
    def sign(_algorithm, key, data)
      raise ArgumentError, "HMAC key required" unless key.is_a?(CryptoKey) && key.algorithm_name == "HMAC"

      OpenSSL::HMAC.digest(openssl_digest_name(key.hash_name), key.__bytes__, coerce_bytes(data)).bytes
    end

    # HMAC verify — constant-time compare of the MAC.
    def verify(_algorithm, key, signature, data)
      raise ArgumentError, "HMAC key required" unless key.is_a?(CryptoKey) && key.algorithm_name == "HMAC"

      expected = OpenSSL::HMAC.digest(openssl_digest_name(key.hash_name), key.__bytes__, coerce_bytes(data))
      sig_bytes = coerce_bytes(signature)
      return false if expected.bytesize != sig_bytes.bytesize

      OpenSSL.fixed_length_secure_compare(expected, sig_bytes)
    end

    def __js_call__(method, args)
      case method
      when "digest"
        digest(args[0], args[1])
      when "generateKey"
        generate_key(args[0], args[1], args[2])
      when "importKey"
        import_key(args[0], args[1], args[2], args[3], args[4])
      when "sign"
        sign(args[0], args[1], args[2])
      when "verify"
        verify(args[0], args[1], args[2], args[3])
      end
    end

    private

    def algorithm_name(algorithm)
      raw = algorithm.is_a?(Hash) ? (algorithm["name"] || algorithm[:name]) : algorithm
      s = raw.to_s.upcase
      # Normalize `SHA256` → `SHA-256`; preserve already-hyphenated `SHA-256`.
      return s if s.include?("-")
      return s.sub("SHA", "SHA-") if s.start_with?("SHA")

      s
    end

    def coerce_bytes(data)
      case data
      when String
        data
      when Array
        data.pack("C*")
      else
        data.respond_to?(:to_a) ? data.to_a.pack("C*") : data.to_s
      end
    end

    def hmac_hash_from(algorithm)
      raw = algorithm.is_a?(Hash) ? (algorithm["hash"] || algorithm[:hash] || algorithm["name"] || algorithm[:name]) : algorithm
      name = raw.to_s
      name = (raw.is_a?(Hash) ? (raw["name"] || raw[:name]) : name).to_s if raw.is_a?(Hash)
      name = algorithm_name(name)
      # Default HMAC hash is SHA-256 per UA practice if "HMAC" was passed alone.
      name == "HMAC" ? "SHA-256" : name
    end

    def openssl_digest_name(hash_name)
      hash_name.sub("SHA-", "SHA")
    end

    def openssl_digest_size(hash_name)
      case hash_name
      when "SHA-1"
        20
      when "SHA-256"
        32
      when "SHA-384"
        48
      when "SHA-512"
        64
      else
        32
      end
    end
  end

  # `CryptoKey` — opaque key handle returned by SubtleCrypto. Raw key
  # bytes are kept private; `extractable: true` exporters are not
  # implemented (use `__bytes__` from Ruby if you really need them).
  class CryptoKey
    attr_reader :type, :algorithm_name, :hash_name, :usages

    def initialize(type, algorithm_name, hash_name, bytes, usages: [])
      @type = type
      @algorithm_name = algorithm_name
      @hash_name = hash_name
      @bytes = bytes
      @usages = usages.map(&:to_s).freeze
    end

    def __bytes__
      @bytes
    end

    def __js_get__(key)
      case key
      when "type"
        @type.to_s
      when "extractable"
        true
      when "algorithm"
        {"name" => @algorithm_name, "hash" => {"name" => @hash_name}}
      when "usages"
        @usages
      end
    end
  end
end
