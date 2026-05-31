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
    def initialize(window = nil)
      @window = window
    end

    # JS: crypto.randomUUID() → version-4 UUID string.
    def random_uuid
      SecureRandom.uuid
    end

    alias randomUUID random_uuid

    # JS: crypto.getRandomValues(typedArray) — fills the supplied
    # buffer in place and returns it. JS TypedArrays carry a
    # `byteLength` property; we honor that to fill multi-byte
    # element arrays (Uint16Array, etc.) correctly. Plain Ruby
    # arrays fall back to `size` (1 byte per slot).
    def get_random_values(typed_array)
      return typed_array unless typed_array.respond_to?(:size) && typed_array.respond_to?(:[]=)

      byte_length = if typed_array.respond_to?(:byteLength)
        typed_array.byteLength
      elsif typed_array.respond_to?(:byte_length)
        typed_array.byte_length
      else
        typed_array.size
      end

      bytes_per_element = [byte_length / typed_array.size, 1].max
      bytes = SecureRandom.bytes(byte_length).bytes
      typed_array.size.times do |i|
        offset = i * bytes_per_element
        value = bytes[offset, bytes_per_element].reduce(0) { |acc, b| (acc << 8) | b }
        typed_array[i] = value
      end

      typed_array
    end

    alias getRandomValues get_random_values

    def subtle
      @subtle ||= SubtleCrypto.new(@window)
    end

    def __js_get__(key)
      case key
      when "subtle"
        subtle
      end
    end

    include Bridge::Methods
    js_methods %w[randomUUID getRandomValues]
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

    def initialize(window = nil)
      @window = window
    end

    def digest(algorithm, data)
      promise do
        name = algorithm_name(algorithm)
        hasher = ALGORITHMS[name]
        raise ArgumentError, "unsupported algorithm: #{name}" unless hasher

        # WHATWG: digest() resolves to an ArrayBuffer — wrap so it crosses the
        # JS boundary as a bare ArrayBuffer (not a plain Array).
        Bridge::ArrayBuffer.new(hasher.call(coerce_bytes(data)).bytes)
      end
    end

    # Generate a fresh symmetric key. `algorithm` is `{name: "HMAC",
    # hash: "SHA-256"}` or `{name: "AES-GCM", length: 128|256}`.
    def generate_key(algorithm, extractable = true, usages = nil)
      promise do
        case primary_algorithm_name(algorithm)
        when "HMAC"
          hash = hmac_hash_from(algorithm)
          CryptoKey.new(
            :secret,
            "HMAC",
            hash,
            SecureRandom.bytes(openssl_digest_size(hash)),
            extractable: extractable,
            usages: usages || %w[sign verify]
          )
        when "AES-GCM", "AES-CBC", "AES-CTR"
          length = (algorithm.is_a?(Hash) && (algorithm["length"] || algorithm[:length])) || 256
          raise ArgumentError, "AES key length must be 128/192/256" unless [128, 192, 256].include?(length)

          CryptoKey.new(
            :secret,
            primary_algorithm_name(algorithm),
            nil,
            SecureRandom.bytes(length / 8),
            extractable: extractable,
            usages: usages || %w[encrypt decrypt]
          )
        else
          raise ArgumentError, "unsupported algorithm: #{primary_algorithm_name(algorithm)}"
        end
      end
    end

    alias generateKey generate_key

    # Import a raw key. Supports HMAC and AES-GCM/CBC/CTR.
    def import_key(format, key_data, algorithm, extractable = true, usages = nil)
      promise do
        raise ArgumentError, "only raw format supported" unless format.to_s == "raw"

        bytes = coerce_bytes(key_data)
        case primary_algorithm_name(algorithm)
        when "HMAC"
          hash = hmac_hash_from(algorithm)
          CryptoKey.new(
            :secret,
            "HMAC",
            hash,
            bytes,
            extractable: extractable,
            usages: usages || %w[sign verify]
          )
        when "AES-GCM", "AES-CBC", "AES-CTR"
          unless [16, 24, 32].include?(bytes.bytesize)
            raise ArgumentError, "AES key must be 16/24/32 bytes"
          end

          CryptoKey.new(
            :secret,
            primary_algorithm_name(algorithm),
            nil,
            bytes,
            extractable: extractable,
            usages: usages || %w[encrypt decrypt]
          )
        else
          raise ArgumentError, "unsupported algorithm: #{primary_algorithm_name(algorithm)}"
        end
      end
    end

    alias importKey import_key

    # HMAC sign — returns the MAC as a byte array.
    def sign(_algorithm, key, data)
      promise do
        raise ArgumentError, "HMAC key required" unless key.is_a?(CryptoKey) && key.algorithm_name == "HMAC"
        raise ArgumentError, "key.usages must include 'sign'" unless key.usages.include?("sign")

        OpenSSL::HMAC.digest(openssl_digest_name(key.hash_name), key.__dommy_bytes__, coerce_bytes(data)).bytes
      end
    end

    # HMAC verify — constant-time compare of the MAC.
    def verify(_algorithm, key, signature, data)
      promise do
        raise ArgumentError, "HMAC key required" unless key.is_a?(CryptoKey) && key.algorithm_name == "HMAC"
        raise ArgumentError, "key.usages must include 'verify'" unless key.usages.include?("verify")

        expected = OpenSSL::HMAC.digest(openssl_digest_name(key.hash_name), key.__dommy_bytes__, coerce_bytes(data))
        sig_bytes = coerce_bytes(signature)
        if expected.bytesize == sig_bytes.bytesize
          OpenSSL.fixed_length_secure_compare(expected, sig_bytes)
        else
          false
        end
      end
    end

    # AES-GCM encrypt. `algorithm` must be `{name: "AES-GCM", iv:
    # <bytes>, additionalData?: <bytes>, tagLength?: 128}`.
    # Output is `ciphertext || authTag`, matching WebCrypto.
    def encrypt(algorithm, key, data)
      promise do
        cipher = build_gcm_cipher(:encrypt, algorithm, key)
        ct = cipher.update(coerce_bytes(data)) + cipher.final
        # OpenSSL always produces a 16-byte tag for GCM; truncate to
        # the requested `tagLength` to honour the spec.
        tag = cipher.auth_tag.byteslice(0, aes_gcm_tag_length(algorithm))
        (ct + tag).bytes
      end
    end

    def decrypt(algorithm, key, data)
      promise do
        bytes = coerce_bytes(data)
        tag_len = aes_gcm_tag_length(algorithm)
        raise ArgumentError, "ciphertext shorter than auth tag" if bytes.bytesize < tag_len

        ct = bytes.byteslice(0, bytes.bytesize - tag_len)
        tag = bytes.byteslice(bytes.bytesize - tag_len, tag_len)
        cipher = build_gcm_cipher(:decrypt, algorithm, key)
        cipher.auth_tag = tag
        (cipher.update(ct) + cipher.final).bytes
      end
    end

    include Bridge::Methods
    js_methods %w[digest generateKey importKey sign verify encrypt decrypt]
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
      when "encrypt"
        encrypt(args[0], args[1], args[2])
      when "decrypt"
        decrypt(args[0], args[1], args[2])
      end
    end

    private

    # Run `block` synchronously and wrap the result (or raised error)
    # in a `PromiseValue`. Required by the WebCrypto spec — every
    # method is `Promise`-returning even when the underlying work is
    # synchronous.
    def promise(&block)
      result = block.call
      PromiseValue.resolve(@window, result)
    rescue StandardError => e
      PromiseValue.reject(@window, e)
    end

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

    # Resolve `algorithm["hash"]` to a canonical hash name (`"SHA-256"`
    # etc.). Accepts the spec shapes:
    #   "SHA-256"                            (bare string)
    #   {hash: "SHA-256"}
    #   {hash: {name: "SHA-256"}}
    #   {name: "HMAC", hash: "SHA-256"}
    # Raises `ArgumentError` if no hash can be resolved — unlike some
    # browser UAs, dommy refuses to silently default to SHA-256.
    def hmac_hash_from(algorithm)
      hash_field = hash_descriptor(algorithm)
      name = algorithm_name(hash_field)

      if name.nil? || name.empty? || name == "HMAC"
        raise ArgumentError, "HMAC requires an explicit hash (e.g. {hash: 'SHA-256'})"
      end

      raise ArgumentError, "unsupported HMAC hash: #{name}" unless ALGORITHMS.key?(name)

      name
    end

    def hash_descriptor(algorithm)
      return algorithm unless algorithm.is_a?(Hash)

      algorithm["hash"] || algorithm[:hash] || algorithm
    end

    # The algorithm's primary name (`"HMAC"` / `"AES-GCM"` / ...) —
    # ignoring any nested `hash` descriptor.
    def primary_algorithm_name(algorithm)
      raw = algorithm.is_a?(Hash) ? (algorithm["name"] || algorithm[:name]) : algorithm
      algorithm_name(raw)
    end

    def openssl_digest_name(hash_name)
      hash_name.sub("SHA-", "SHA")
    end

    def aes_gcm_tag_length(algorithm)
      bits = (algorithm.is_a?(Hash) && (algorithm["tagLength"] || algorithm[:tagLength])) || 128
      bits / 8
    end

    def build_gcm_cipher(direction, algorithm, key)
      raw_key = key.is_a?(CryptoKey) ? key.__dommy_bytes__ : coerce_bytes(key)
      raise ArgumentError, "AES-GCM key must be 16/24/32 bytes" unless [16, 24, 32].include?(raw_key.bytesize)

      iv = algorithm.is_a?(Hash) ? (algorithm["iv"] || algorithm[:iv]) : nil
      raise ArgumentError, "AES-GCM requires an iv" if iv.nil?

      cipher = OpenSSL::Cipher.new("aes-#{raw_key.bytesize * 8}-gcm")
      direction == :encrypt ? cipher.encrypt : cipher.decrypt
      cipher.key = raw_key
      cipher.iv = coerce_bytes(iv)
      aad = algorithm.is_a?(Hash) ? (algorithm["additionalData"] || algorithm[:additionalData]) : nil
      cipher.auth_data = coerce_bytes(aad) if aad
      cipher
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

  # `CryptoKey` — opaque key handle returned by SubtleCrypto.
  # `extractable: false` keys reject export attempts; the raw bytes are
  # reachable only through the `__dommy_bytes__` ecosystem accessor, never
  # the public (Web-mirroring) API.
  class CryptoKey
    attr_reader :type, :algorithm_name, :hash_name, :usages, :extractable

    def initialize(type, algorithm_name, hash_name, bytes, extractable: true, usages: [])
      @type = type
      @algorithm_name = algorithm_name
      @hash_name = hash_name
      @bytes = bytes
      @extractable = extractable
      @usages = usages.map(&:to_s).freeze
    end

    # Low-level ecosystem accessor (see __dommy_ convention) — the public
    # Web API never exposes raw key bytes.
    def __dommy_bytes__
      @bytes
    end

    def __js_get__(key)
      case key
      when "type"
        @type.to_s
      when "extractable"
        @extractable
      when "algorithm"
        {"name" => @algorithm_name, "hash" => {"name" => @hash_name}}
      when "usages"
        @usages
      end
    end
  end
end
