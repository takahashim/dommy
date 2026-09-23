# frozen_string_literal: true

module Dommy
  module Bridge
    # The exceptions a spec mandates the JS side see as something other than a
    # DOMException — a real TypeError, a real RangeError, or an arbitrary thrown
    # value. Each is kept distinct from Ruby's own so a host maps only the
    # deliberate ones and never masks a genuine Ruby bug.

    # Raised by a host method that must throw an ARBITRARY value back to JS —
    # not a DOMException/Error, but e.g. `signal.throwIfAborted()` throwing the
    # exact abort reason (a string, number, or opaque JSValue). The bridge
    # re-throws the wrapped value verbatim (identity preserved). Subclasses
    # RuntimeError (with the value's string form as the message) so standalone
    # CRuby callers still see a normal `raise`-able error.
    class ThrowValue < RuntimeError
      attr_reader :value

      # `message` overrides the value's string form, for a caller that can say
      # more about it than `to_s` can (a JS error's kind, say).
      def initialize(value, message = nil)
        @value = value
        super(message || value.to_s)
      end
    end

    # A Ruby-side signal that the JS boundary should surface a JS `TypeError`
    # (not a `DOMException`). Some WebIDL operations — notably the `URL`
    # constructor and its `href` setter — throw `TypeError` on failure rather
    # than a DOMException; raising this lets a host bridge rethrow the correct
    # JS error type, while Ruby callers can still rescue it like any other
    # error. Kept distinct from Ruby's built-in `::TypeError` so a host can map
    # only deliberate, spec-mandated TypeErrors (and not mask genuine Ruby type
    # bugs) across the boundary.
    class TypeError < ::StandardError; end

    # Like `Bridge::TypeError`, but for spec-mandated `RangeError`s (e.g. the
    # `Response` constructor rejecting a status outside 200–599). A host bridge
    # rethrows a real JS `RangeError`; kept distinct from Ruby's `::RangeError`.
    class RangeError < ::StandardError; end
  end
end
