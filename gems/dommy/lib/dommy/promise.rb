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
    js_methods %w[then catch]
    def __js_call__(method, args)
      case method
      when "then"
        attach_then(args[0], args[1])
      when "catch"
        attach_then(nil, args[0])
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
      @window&.scheduler&.drain_microtasks

      case @state
      when :fulfilled
        @value
      when :rejected
        raise unwrap_rejection(@value)
      else
        raise "Promise#await: still pending after microtask drain"
      end
    end

    private

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

    def settle(state, value)
      return self if settled?

      if value.is_a?(PromiseValue)
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
      if callback.nil?
        propagate(handler.child)
        return
      end

      result = CallableInvoker.invoke(callback, @value)
      if result.is_a?(PromiseValue) && !result.equal?(handler.child)
        # Adopt the returned thenable. The continuation procs return nil so their
        # `self`-returning fulfill/reject don't get re-adopted (infinite chain).
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

    rescue StandardError => e
      handler.child.reject(ErrorValue.new(e.message, name: e.class.to_s))
    end

    def propagate(child)
      @state == :fulfilled ? child.fulfill(@value) : child.reject(@value)
    end
  end
end
