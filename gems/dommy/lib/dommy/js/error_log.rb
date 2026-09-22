# frozen_string_literal: true

module Dommy
  # Raised when the page left JavaScript errors unhandled and the host is in
  # strict mode. "Unhandled" is the page's own verdict: an error it cancels in
  # `window.onerror` / `unhandledrejection` never gets here (see
  # `Window#__internal_report_exception__`), exactly as a browser console would
  # stay quiet.
  class JsError < StandardError
    attr_reader :causes

    # `context` is where the page was when the errors surfaced. Without it a
    # failure deep inside a waiting matcher reads as a bare stack trace with no
    # hint that the cause was the page's own JavaScript.
    def initialize(causes, context: nil)
      @causes = causes
      super(build_message(causes, context))
    end

    private

    def build_message(causes, context)
      lines = causes.map { |cause| "  #{cause.class}: #{cause.message}" }
      header = "#{causes.length} uncaught JS error(s)"
      header += " at #{context}" if context && !context.to_s.empty?
      "#{header}:\n#{lines.join("\n")}"
    end
  end

  module Js
    # The one ledger of JavaScript errors a page left unhandled, shared by every
    # host that runs page JS (`Dommy::Browser`, `Dommy::Rack::Session`, and the
    # test front ends on top of them).
    #
    # It keeps two views of the same errors, and the split is the point:
    #
    # - `errors` is the HISTORY, the console's scrollback. A host clears it on
    #   navigation, because a browser's console clears when the page changes.
    # - `pending` is the UNACKNOWLEDGED queue, which only a checkpoint (`check!`)
    #   or `allow` drains. It is a queue rather than an index into the history
    #   precisely so that clearing the history cannot silently swallow it: an
    #   index would point past the end of a freshly cleared list, and the new
    #   page's boot errors would read as "none".
    class ErrorLog
      attr_reader :errors

      def initialize(strict: true)
        @strict = strict
        @errors = []
        @pending = []
        @allowing = false
        @last_id = 0
      end

      # Whether a checkpoint raises. A non-strict log still records everything,
      # for a host that only wants to read the errors (an embedding browser).
      attr_accessor :strict

      # Record an error the page did not handle.
      #
      # Returns an id for the entry. Nothing consumes it yet: it is the seam for
      # retracting a report later, which HTML needs for `rejectionhandled` (a
      # promise reported as unhandled, then given a handler after all). No JS
      # engine tells us that today, so the retraction itself is deliberately not
      # implemented — but the id means adding it will not have to change every
      # call site that records.
      def record(error)
        @last_id += 1
        @errors << error
        @pending << Entry.new(@last_id, error)
        @last_id
      end

      # Fail if the page left errors unhandled since the last checkpoint. The
      # queue is drained either way, so each error is reported at most once.
      def check!(context: nil)
        return if @allowing || !@strict

        causes = drain
        return if causes.empty?

        raise JsError.new(causes, context: context)
      end

      # Suppress checkpoint failures for the block, for a test that triggers an
      # error on purpose. The errors stay in `errors` for inspection; the queue
      # is drained on the way out so a later checkpoint does not re-report them.
      def allow
        previous = @allowing
        @allowing = true
        yield
      ensure
        @allowing = previous
        drain
      end

      # Errors recorded but not yet reported, oldest first.
      def pending = @pending.map(&:error)

      def pending? = !@pending.empty?

      # Drop the history, keeping the unacknowledged queue intact. A host calls
      # this when the page navigates: the console's scrollback belongs to the
      # document that just went away, but an error that document produced and
      # nobody has reported yet still has to fail the test.
      def clear_history
        @errors.clear
        nil
      end

      private

      Entry = Struct.new(:id, :error)

      def drain
        causes = @pending.map(&:error)
        @pending.clear
        causes
      end
    end
  end
end
