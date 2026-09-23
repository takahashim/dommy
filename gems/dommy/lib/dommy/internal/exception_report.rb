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

      # One JS stack frame, in either of the two forms an engine writes:
      # `at name (file:line:col)` and the anonymous `at file:line:col`.
      STACK_FRAME = /\Aat\s+(?:\S+\s+\()?(?<file>.+?):(?<line>\d+):(?<column>\d+)\)?\z/

      # Frames inside Dommy's own JS plumbing. The page did not write them, so
      # they must not be reported as where its error happened.
      INTERNAL_SOURCES = %w[host_runtime.js observable_runtime.js].freeze

      # Where the error happened, as `ErrorEvent`'s [filename, lineno, colno].
      # A JS engine puts its frames on the raised exception's backtrace, so the
      # topmost frame the PAGE owns is the position to report. Zeroes when there
      # is no usable frame, which is what the spec says to expose when the
      # position is unknown.
      def source_position(error)
        Array(error.backtrace).each do |frame|
          match = STACK_FRAME.match(frame.to_s.strip)
          next unless match
          next if INTERNAL_SOURCES.any? { |source| match[:file].end_with?(source) }

          return [match[:file], match[:line].to_i, match[:column].to_i]
        end
        ["", 0, 0]
      end

      # WHATWG "report an exception" at `window`, shaping the thrown value, its
      # message and its source position from whatever the entry point caught.
      # Every entry point reports through here, so none of them can drift from
      # the others in what the page gets to see. Returns whether the page
      # handled it.
      # `value` overrides what the page sees as `event.error`, for a caller that
      # can supply a better one than the raw catch: an engine that converted the
      # throw to a host exception can rebuild the JS Error the page threw, which
      # is the difference between a handler reading `.message` and one crashing
      # on `undefined`.
      def report_at(window, error, value: nil)
        value ||= error_value(error)
        message = message_for(error)
        file, line, column = source_position(error)
        window.__internal_report_exception__(value, message,
          filename: document_source(file, window), lineno: line, colno: column, host_error: error)
      end

      # What an engine calls source it was handed with no name of its own — an
      # inline `<script>`, an `eval`. A browser reports the document's URL for
      # those, so the placeholder is swapped for it rather than leaking an
      # engine-internal name into `ErrorEvent#filename`.
      ANONYMOUS_SOURCES = ["<code>", "<input>", "<eval>", "<anonymous>"].freeze

      def document_source(file, window)
        return file unless ANONYMOUS_SOURCES.include?(file)

        location = window.location if window.respond_to?(:location)
        location.respond_to?(:href) ? location.href.to_s : file
      end

      # A host-loggable exception for a value that came straight off the bridge
      # with no exception attached — a rejection reason, which the engine hands
      # over as the JS value itself. `Bridge::ThrowValue` is that shape already:
      # it is raisable, keeps the value, and takes the JS frames as its backtrace
      # so the report can still say where the page failed.
      def thrown_host_error(value)
        return value if value.is_a?(::Exception)

        name = value.js_name if value.respond_to?(:js_name)
        text = value.to_s
        error = Bridge::ThrowValue.new(value, name && name != "Object" ? "#{name}: #{text}" : text)
        frames = value.respond_to?(:stack_frames) ? value.stack_frames : nil
        error.set_backtrace(frames) if frames && !frames.empty?
        error
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
