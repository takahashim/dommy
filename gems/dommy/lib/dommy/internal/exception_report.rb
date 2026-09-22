# frozen_string_literal: true

module Dommy
  module Internal
    # Shared shaping for WHATWG "report an exception": turn whatever a throwing
    # entry point handed us into the pair the report needs — the value to expose
    # as `ErrorEvent#error` and the string to expose as `ErrorEvent#message`.
    #
    # Two shapes arrive. A JS callback's throw comes wrapped in a
    # `Bridge::ThrowValue` carrying the thrown JS value with its identity intact
    # (so `event.error === thrown` holds in the page); everything else is a plain
    # Ruby exception raised by the host or the engine. Unwrapping in one place
    # keeps every report site (event dispatch, script evaluation, a timer
    # callback, `reportError`) agreeing on what the page sees.
    module ExceptionReport
      module_function

      # The `error` value a report should expose: a ThrowValue's payload keeps
      # JS identity, anything else reports itself.
      def error_value(error)
        error.is_a?(Bridge::ThrowValue) ? error.value : error
      end

      # The `message` a report should expose for `error`. A JS Error proxy and a
      # Ruby exception both answer `message`; a thrown non-Error (a string, an
      # object literal) has only its string form.
      def message_for(error)
        value = error_value(error)
        return value.message.to_s if value.respond_to?(:message)

        value.to_s
      end

      # Both halves at once, for a caller that needs the pair.
      def describe(error)
        [error_value(error), message_for(error)]
      end

      # The form the HOST logs. A report's `error` value is whatever the page
      # threw, which for JS code is an opaque `Bridge::JSValue` with no `class` /
      # `message` / backtrace — everything an error log wants. A caller that has
      # the original Ruby exception passes it as `host_error`; otherwise the bare
      # value is wrapped, so the log never has to special-case what it holds.
      def host_form(error_value, host_error)
        return host_error if host_error
        return error_value if error_value.is_a?(::Exception)

        Bridge::ThrowValue.new(error_value)
      end
    end
  end
end
