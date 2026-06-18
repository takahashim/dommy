# frozen_string_literal: true

module Dommy
  # The async-network handoff for fetch / XHR. A `__fetch_handler__` (or XHR stub
  # lookup) may return one of these instead of a response entry to answer a
  # request ASYNCHRONOUSLY: the response is produced off the page thread (e.g. by
  # a network worker doing blocking HTTP), and `#complete(entry)` is called from
  # that thread when it is ready. Delivery is routed through the scheduler's
  # external inbox, so the waiting fetch/XHR is fulfilled on the PAGE thread —
  # single-threaded with the DOM/JS. The worker only ever passes a plain entry
  # Hash (status / headers / body bytes); it never touches Dommy/JS state.
  #
  # `#complete` is thread-safe and races cleanly with `#on_complete` (whichever
  # of register / complete happens last triggers the single delivery).
  class DeferredResponse
    def initialize(scheduler)
      @scheduler = scheduler
      @mutex = Mutex.new
      @on_complete = nil
      @entry = nil
      @completed = false
      @flushed = false
    end

    # fetch/XHR registers its delivery callback here (invoked on the page thread
    # with the response entry, or nil for a network failure -> a 404-style miss).
    def on_complete(&block)
      @mutex.synchronize { @on_complete = block }
      flush
      self
    end

    # Called by the worker thread when the response (or nil) is ready. THREAD-SAFE.
    def complete(entry)
      @mutex.synchronize do
        @entry = entry
        @completed = true
      end
      flush
    end

    private

    # Once BOTH the callback is registered and the response has arrived, post the
    # one-shot delivery onto the page thread's inbox.
    def flush
      callback = nil
      entry = nil
      @mutex.synchronize do
        return if @flushed || !@completed || @on_complete.nil?

        @flushed = true
        callback = @on_complete
        entry = @entry
      end
      @scheduler.post_external { callback.call(entry) }
    end
  end
end
