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
      @store[key.to_s]
    end

    def set_item(key, value)
      @store[key.to_s] = value.to_s
      nil
    end

    def remove_item(key)
      @store.delete(key.to_s)
      nil
    end

    def clear
      @store.clear
      nil
    end

    def key(index)
      @store.keys[index.to_i]
    end

    def [](key)
      @store[key.to_s]
    end

    def []=(key, value)
      @store[key.to_s] = value.to_s
    end

    def __js_get__(key)
      case key
      when "length"
        @store.size
      else
        @store[key.to_s]
      end
    end

    def __js_set__(key, value)
      @store[key.to_s] = value.to_s
    end

    include Bridge::Methods
    js_methods %w[getItem setItem removeItem clear key]
    def __js_call__(method, args)
      case method
      when "getItem"
        @store[args[0].to_s]
      when "setItem"
        @store[args[0].to_s] = args[1].to_s
        nil
      when "removeItem"
        @store.delete(args[0].to_s)
        nil
      when "clear"
        @store.clear
        nil
      when "key"
        @store.keys[args[0].to_i]
      end
    end
  end
end
