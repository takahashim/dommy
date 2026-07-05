# frozen_string_literal: true

module Dommy
  # Hash-backed `Storage` polyfill for `localStorage` /
  # `sessionStorage`. Mirrors the Web Storage API:
  # `getItem(key)`, `setItem(key, value)`, `removeItem(key)`,
  # `clear()`, `key(index)`, `length`. Values are coerced to String
  # to match browser semantics (browser stores everything as String).
  #
  # No persistence across Window instances — each fresh Window gets
  # an empty Storage. Tests that depend on cross-instance behaviour
  # (none currently) would need explicit hydration.
  class Storage
    include Enumerable

    def initialize
      @store = {}
    end

    # Ruby-idiomatic facade matching `Object.keys(storage)` /
    # `Object.values(storage)` / `Object.entries(storage)` semantics
    # that user code reaches for in browser JS.

    def keys
      @store.keys
    end

    def values
      @store.values
    end

    def entries
      @store.to_a
    end

    def to_h
      @store.dup
    end

    def each(&blk)
      @store.each(&blk)
    end

    def length
      @store.size
    end

    alias size length

    def get_item(key)
      @store[web_string(key)]
    end

    def set_item(key, value)
      @store[web_string(key)] = web_string(value)
      nil
    end

    def remove_item(key)
      @store.delete(web_string(key))
      nil
    end

    def clear
      @store.clear
      nil
    end

    def key(index)
      @store.keys[to_index(index)]
    end

    def [](key)
      @store[web_string(key)]
    end

    def []=(key, value)
      @store[web_string(key)] = web_string(value)
    end

    def __js_get__(key)
      case key
      when "length"
        @store.size
      else
        # A named-property miss is JS `undefined` (and `"k" in storage` false).
        @store.key?(key.to_s) ? @store[key.to_s] : Bridge::ABSENT
      end
    end

    # Named setter: the proxy key is already a String; the value is ToString-
    # coerced JS-side (WebIDL DOMString named setter) before crossing.
    def __js_set__(key, value)
      @store[key.to_s] = value.to_s
    end

    # Named deleter (`delete storage[key]`): the browser's Storage removes the
    # entry. Always "succeeds" so the JS `delete` returns true.
    def __js_delete__(key)
      @store.delete(key.to_s)
      true
    end

    # WebIDL "supported property names": the current keys, so `Object.keys` /
    # `for…in` / spread enumerate only the stored entries (not the builtins,
    # which live on Storage.prototype).
    def __js_named_props__
      @store.keys
    end

    include Bridge::Methods
    js_methods %w[getItem setItem removeItem clear key]
    def __js_call__(method, args)
      case method
      when "getItem"
        require_args!(method, args, 1)
        @store[web_string(args[0])]
      when "setItem"
        require_args!(method, args, 2)
        @store[web_string(args[0])] = web_string(args[1])
        nil
      when "removeItem"
        require_args!(method, args, 1)
        @store.delete(web_string(args[0]))
        nil
      when "clear"
        @store.clear
        nil
      when "key"
        require_args!(method, args, 1)
        @store.keys[to_index(args[0])]
      end
    end

    private

    # WebIDL DOMString coercion of a method argument: JS null → "null",
    # undefined → "undefined", everything else via ToString.
    def web_string(value)
      return "null" if value.nil?
      return "undefined" if value.equal?(Bridge::UNDEFINED)

      value.to_s
    end

    # WebIDL `unsigned long` index coercion (ToUint32): out-of-range / huge
    # indices wrap mod 2**32 (so `key(2**32)` behaves like `key(0)`), and
    # non-numeric values become 0.
    def to_index(value)
      n = value.equal?(Bridge::UNDEFINED) ? 0 : Integer(value.to_i)
      n % (1 << 32)
    rescue StandardError
      0
    end

    # A missing required argument is a TypeError (not a DOMException), matching
    # the WebIDL overload-resolution error for too few arguments.
    def require_args!(method, args, arity)
      return if args.length >= arity

      raise Bridge::TypeError,
            "Failed to execute '#{method}' on 'Storage': #{arity} argument#{"s" if arity > 1} required, " \
            "but only #{args.length} present."
    end
  end
end
