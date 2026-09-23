# frozen_string_literal: true

module Dommy
  module Bridge
    # The three values that are not values: what the protocol says when a
    # property is missing, undefined, or not ours to handle. Every host has to
    # tell these apart, which is why they are Bridge's.

    # Sentinel returned by `__js_set__` when a key is not a known DOM property
    # (so the JS host can keep it as a JS-side expando, preserving identity)
    # rather than silently dropping it.
    UNHANDLED = :__js_unhandled__

    # Sentinel for the JS `undefined` value, used in both directions:
    #   - a `__js_call__` returns it for a void (undefined-returning) op, so the
    #     host marshals JS `undefined` rather than the `null` a bare Ruby `nil`
    #     would (e.g. DOMTokenList add/remove return undefined);
    #   - a top-level JS `undefined` *argument* arrives as it (whereas JS `null`
    #     arrives as `nil`), so WebIDL-style dispatch can tell an omitted optional
    #     argument from an explicit null.
    # Its `to_s` is "undefined" so a DOMString coercion of a stray undefined is
    # still spec-faithful.
    UNDEFINED = Object.new
    def UNDEFINED.to_s = "undefined"
    def UNDEFINED.inspect = "#<Dommy::Bridge::UNDEFINED>"
    UNDEFINED.freeze

    # The sentinel a `__js_get__` returns for a GENUINELY-ABSENT property (a key
    # the object does not have), as distinct from a present property whose value
    # is `nil`/JS null or `UNDEFINED`/JS undefined. It marshals to JS `undefined`
    # for the value, but the proxy reports `("x" in obj) === false` for it — so
    # feature detection like `isUndefined(window.Vue)` AND `"Vue" in window` are
    # both correct. (UNDEFINED means present-but-undefined → reported present.)
    ABSENT = Object.new
    def ABSENT.to_s = "undefined"
    def ABSENT.inspect = "#<Dommy::Bridge::ABSENT>"
    ABSENT.freeze
  end
end
