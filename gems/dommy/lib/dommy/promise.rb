# frozen_string_literal: true

module Dommy
  class ErrorValue
    def initialize(message = nil, name: "Error")
      @message = message.to_s
      @name = name
    end

    def __js_get__(key)
      case key
      when "message"
        @message
      when "name"
        @name
      else
        Bridge::ABSENT
      end
    end

    def to_s
      return @name if @message.empty?

      "#{@name}: #{@message}"
    end
  end

  # Note: `PromiseConstructor` and `PromiseSettler` live in
  # `Dommy::Bridge::*` — they're bridge-adapter classes for the
  # `JS.global[:Promise]` view, not part of the public DOM surface.

  class PromiseValue
    Handler = Struct.new(:on_fulfilled, :on_rejected, :child)

    def self.resolve(window, value)
      promise = new(window)
      promise.fulfill(value)
      promise
    end

    def self.reject(window, reason)
      promise = new(window)
      promise.reject(reason)
      promise
    end

    def initialize(window)
      @window = window
      @state = :pending
      @value = nil
      @handlers = []
    end

    include Bridge::Methods
    js_methods %w[then catch finally]
    def __js_call__(method, args)
      case method
      when "then"
        attach_then(args[0], args[1])
      when "catch"
        attach_then(nil, args[0])
      when "finally"
        attach_finally(args[0])
      else
        nil
      end
    end

    def fulfill(value)
      settle(:fulfilled, value)
    end

    def reject(reason)
      settle(:rejected, reason)
    end

    # Synchronously unwrap the promise's settled value, or raise its
    # rejection. Dommy's scheduler is deterministic, so "wait" is
    # spelled "drain queued microtasks then read the state."
    #
    # This is the bridge between dommy's async APIs (fetch, etc.) and
    # Ruby tests that want to write straight-line code:
    #
    #   response = win.__js_call__("fetch", [url]).await
    #   text     = response.text
    #
    # Raises `RuntimeError` if the promise is still pending after a
    # microtask drain — that's a sign that real-time work (e.g. a
    # `setTimeout`) needs to advance via `advance_time` first.
    def await
      drive_until_settled

      case @state
      when :fulfilled
        @value
      when :rejected
        raise unwrap_rejection(@value)
      else
        raise "Promise#await: still pending after draining the event loop"
      end
    end

    private

    # Drive the event loop over the work that is ready NOW until this promise
    # settles: `advance_time(0)` runs the microtask checkpoint plus every task
    # already due (a fetch's setTimeout(0) delivery and anything it queues),
    # WITHOUT moving the clock forward. A promise waiting on a real delay
    # (setTimeout(100)) is left pending — that still needs an explicit
    # `advance_time`, so #await reports it pending rather than silently jumping
    # virtual time. Bounded against a self-rescheduling setTimeout(0).
    def drive_until_settled
      sched = @window&.scheduler
      return unless sched

      64.times do
        sched.advance_time(0)
        break unless @state == :pending && sched.next_due_timer_at == sched.now_ms
      end
    end

    def unwrap_rejection(value)
      case value
      when Exception
        value
      when ErrorValue
        RuntimeError.new(value.to_s)
      else
        RuntimeError.new(value.to_s)
      end
    end

    def attach_then(on_fulfilled, on_rejected)
      child = self.class.new(@window)
      @handlers << Handler.new(on_fulfilled, on_rejected, child)
      schedule_flush if settled?
      child
    end

    # ES2018 `finally(onFinally)` — run `onFinally` (no args) whichever way the
    # promise settles, then PASS THROUGH the original value/reason. Equivalent to
    # `then(v => P.resolve(onFinally()).then(() => v),
    #       e => P.resolve(onFinally()).then(() => { throw e }))`:
    # onFinally can't change the resolution value, but if it throws or returns a
    # rejected promise that rejection wins, and a returned promise is awaited
    # before passing through. A non-callable onFinally is a plain passthrough.
    # `fetch(...).finally(hideSpinner)` is ubiquitous, so a missing `finally`
    # crashes real bundles (hatena's ad/guide scripts hit exactly this).
    def attach_finally(on_finally)
      return attach_then(on_finally, on_finally) unless callable?(on_finally)

      on_fulfilled = proc { |value| coerce_to_promise(call_finally(on_finally)).__js_call__("then", [proc { value }]) }
      on_rejected = proc { |reason|
        coerce_to_promise(call_finally(on_finally)).__js_call__("then", [proc { raise Bridge::ThrowValue.new(reason) }])
      }
      attach_then(on_fulfilled, on_rejected)
    end

    # Invoke onFinally with no arguments, in raising mode so a throw rejects the
    # finally-chain (run_handler's rescue carries the thrown value through).
    def call_finally(on_finally)
      if on_finally.respond_to?(:__js_call_with_raise__)
        on_finally.__js_call_with_raise__([])
      else
        on_finally.call
      end
    end

    def coerce_to_promise(value)
      value.is_a?(PromiseValue) ? value : self.class.resolve(@window, value)
    end

    def settle(state, value)
      return self if settled?

      # Only RESOLUTION adopts a promise — fulfilling with a host promise takes
      # its eventual state (Promises/A+ §2.3.2). A rejection REASON is never
      # resolved: `reject(aPromise)` rejects WITH that promise as the reason, so
      # `then(null, r => r === aPromise)` holds (2.3.3.3.2 with a promise reason).
      if state == :fulfilled && value.is_a?(PromiseValue)
        return adopt(value)
      end

      @state = state
      @value = value
      schedule_flush
      self
    end

    def adopt(other)
      other.__js_call__(
        "then",
        [
          # Return nil, not the result of fulfill/reject: those return `self`
          # (a PromiseValue), and run_handler would treat that as a thenable to
          # chain onto — re-adopting forever. These are adoption sinks; their
          # return value must be ignored.
          proc { |resolved| fulfill(resolved); nil },
          proc { |reason| reject(reason); nil }
        ]
      )
      self
    end

    def settled?
      @state != :pending
    end

    def schedule_flush
      @window.scheduler.queue_microtask(proc { flush_handlers })
      nil
    end

    def flush_handlers
      return unless settled?
      return if @handlers.empty?

      handlers = @handlers.dup
      @handlers.clear
      handlers.each do |handler|
        run_handler(handler)
      end
    end

    def run_handler(handler)
      callback = @state == :fulfilled ? handler.on_fulfilled : handler.on_rejected
      unless callable?(callback)
        # §2.2.7.3/.4: a non-function handler (`then(5)`, `then(null, {})`) passes
        # the settled state straight through to the child, value/reason intact.
        propagate(handler.child)
        return
      end

      result = invoke_handler(callback, @value)
      if result.equal?(handler.child)
        # §2.3.1: a handler returning its own promise is a cycle — reject with a
        # TypeError rather than adopting itself forever.
        handler.child.reject(Bridge::TypeError.new("Chaining cycle detected for promise"))
      elsif result.is_a?(PromiseValue)
        # Adopt the returned host promise. The continuation procs return nil so
        # their `self`-returning fulfill/reject don't get re-adopted (infinite
        # chain).
        result.__js_call__(
          "then",
          [
            proc { |resolved| handler.child.fulfill(resolved); nil },
            proc { |reason| handler.child.reject(reason); nil }
          ]
        )
      else
        handler.child.fulfill(result)
      end

    rescue Bridge::ThrowValue => e
      # §2.2.7.2: the handler threw — reject the child with the thrown value
      # ITSELF (identity preserved across the bridge), not a wrapping ErrorValue.
      handler.child.reject(e.value)
    rescue StandardError => e
      handler.child.reject(ErrorValue.new(e.message, name: e.class.to_s))
    end

    # A callable handler is a JS function (HostCallback) or a Ruby proc; a plain
    # value (number, null, object) is not, and triggers §2.2.7.3/.4 passthrough.
    def callable?(callback)
      callback.respond_to?(:__js_call__) || callback.respond_to?(:call)
    end

    # Invoke a `.then` handler. A JS callback is invoked in RAISING mode so a
    # thrown value re-raises as a Bridge::ThrowValue (§2.2.7.2) instead of being
    # swallowed; a Ruby callable raises naturally.
    def invoke_handler(callback, value)
      if callback.respond_to?(:__js_call_with_raise__)
        callback.__js_call_with_raise__([value])
      else
        CallableInvoker.invoke(callback, value)
      end
    end

    def propagate(child)
      @state == :fulfilled ? child.fulfill(@value) : child.reject(@value)
    end
  end
end
