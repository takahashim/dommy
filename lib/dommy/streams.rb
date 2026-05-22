# frozen_string_literal: true

module Dommy
  # Minimal Streams API: `ReadableStream` + `WritableStream` +
  # `TransformStream`. Strictly enough surface for tests that iterate
  # `fetch().body` or chain a small pipeline. No backpressure, no
  # locked-state policing beyond the basics.
  #
  # Spec: https://streams.spec.whatwg.org/

  # `ReadableStream` — implements the pull-from-source pattern via an
  # `underlyingSource` whose `start` / `pull` callbacks receive a
  # `Controller` to enqueue chunks. `getReader()` yields a
  # `ReadableStreamDefaultReader` exposing `.read()` (Promise of
  # `{ value:, done: }`).
  class ReadableStream
    attr_reader :state

    def initialize(window, underlying_source = nil)
      @window = window
      @queue = []
      @state = :readable
      @reader = nil
      @pending_reads = []
      @controller = ReadableStreamDefaultController.new(self)

      source = underlying_source.is_a?(Hash) ? underlying_source.transform_keys(&:to_s) : {}
      @pull_callback = source["pull"]

      start = source["start"]
      invoke(start, [@controller]) if start
    end

    def get_reader
      raise Error, "stream locked" if @reader

      @reader = ReadableStreamDefaultReader.new(self)
    end

    alias getReader get_reader

    def locked
      !@reader.nil?
    end

    def cancel(_reason = nil)
      @state = :closed
      @queue.clear
      flush_pending_reads
      PromiseValue.resolve(@window, nil)
    end

    # Convenience: iterate all chunks synchronously into an Array.
    def __drain__
      out = []
      until @queue.empty?
        out << @queue.shift
      end

      out
    end

    def __enqueue__(chunk)
      raise Error, "stream is not readable" unless @state == :readable

      @queue << chunk
      flush_pending_reads
    end

    def __close__
      @state = :closed
      flush_pending_reads
    end

    def __error__(reason)
      @state = :errored
      @error_reason = reason
      flush_pending_reads
    end

    def __read__
      promise = PromiseValue.new(@window)

      if !@queue.empty?
        promise.fulfill({"value" => @queue.shift, "done" => false})
      elsif @state == :closed
        promise.fulfill({"value" => nil, "done" => true})
      elsif @state == :errored
        promise.reject(@error_reason)
      else
        @pending_reads << promise
        invoke(@pull_callback, [@controller]) if @pull_callback
      end

      promise
    end

    def __js_get__(key)
      case key
      when "locked"
        locked
      end
    end

    def __js_call__(method, args)
      case method
      when "getReader"
        get_reader
      when "cancel"
        cancel(args[0])
      end
    end

    class Error < StandardError
    end

    private

    def flush_pending_reads
      while !@pending_reads.empty? && (!@queue.empty? || @state == :closed || @state == :errored)
        promise = @pending_reads.shift
        if !@queue.empty?
          promise.fulfill({"value" => @queue.shift, "done" => false})
        elsif @state == :errored
          promise.reject(@error_reason)
        else
          promise.fulfill({"value" => nil, "done" => true})
        end
      end
    end

    def invoke(callback, args)
      return if callback.nil?

      if callback.respond_to?(:__js_call__)
        callback.__js_call__("call", args)
      elsif callback.respond_to?(:call)
        callback.call(*args)
      end
    end
  end

  # Controller passed to ReadableStream's `start` / `pull` callbacks.
  class ReadableStreamDefaultController
    def initialize(stream)
      @stream = stream
    end

    def enqueue(chunk)
      @stream.__enqueue__(chunk)
    end

    def close
      @stream.__close__
    end

    def error(reason)
      @stream.__error__(reason)
    end

    def __js_call__(method, args)
      case method
      when "enqueue"
        enqueue(args[0])
      when "close"
        close
      when "error"
        error(args[0])
      end
    end
  end

  # Reader returned by `getReader()`.
  class ReadableStreamDefaultReader
    def initialize(stream)
      @stream = stream
    end

    def read
      @stream.__read__
    end

    def release_lock
      # Spec: detaches the reader. We model the stream's `@reader`
      # slot indirectly via `releaseLock` accessibility.
      nil
    end

    alias releaseLock release_lock

    def cancel(reason = nil)
      @stream.cancel(reason)
    end

    def __js_call__(method, args)
      case method
      when "read"
        read
      when "releaseLock"
        release_lock
      when "cancel"
        cancel(args[0])
      end
    end
  end

  # `WritableStream` — accepts chunks via a writer; persistence is up
  # to the `underlyingSink`'s `write` callback.
  class WritableStream
    def initialize(window, underlying_sink = nil)
      @window = window
      @writer = nil
      @state = :writable
      @sink = underlying_sink.is_a?(Hash) ? underlying_sink.transform_keys(&:to_s) : {}
      invoke(@sink["start"], [])
    end

    def get_writer
      raise Error, "stream locked" if @writer

      @writer = WritableStreamDefaultWriter.new(self)
    end

    alias getWriter get_writer

    def locked
      !@writer.nil?
    end

    def __write__(chunk)
      invoke(@sink["write"], [chunk])
      PromiseValue.resolve(@window, nil)
    end

    def __close__
      @state = :closed
      invoke(@sink["close"], [])
      PromiseValue.resolve(@window, nil)
    end

    def __abort__(reason)
      @state = :errored
      invoke(@sink["abort"], [reason])
      PromiseValue.resolve(@window, nil)
    end

    def __js_get__(key)
      case key
      when "locked"
        locked
      end
    end

    def __js_call__(method, args)
      case method
      when "getWriter"
        get_writer
      when "close"
        __close__
      when "abort"
        __abort__(args[0])
      end
    end

    class Error < StandardError
    end

    private

    def invoke(callback, args)
      return if callback.nil?

      if callback.respond_to?(:__js_call__)
        callback.__js_call__("call", args)
      elsif callback.respond_to?(:call)
        callback.call(*args)
      end
    end
  end

  class WritableStreamDefaultWriter
    def initialize(stream)
      @stream = stream
    end

    def write(chunk)
      @stream.__write__(chunk)
    end

    def close
      @stream.__close__
    end

    def abort(reason = nil)
      @stream.__abort__(reason)
    end

    def __js_call__(method, args)
      case method
      when "write"
        write(args[0])
      when "close"
        close
      when "abort"
        abort(args[0])
      end
    end
  end

  # `TransformStream` — links a writable + readable so chunks flow
  # through a `transform` callback.
  class TransformStream
    attr_reader :readable, :writable

    def initialize(window, transformer = nil)
      @window = window
      t = transformer.is_a?(Hash) ? transformer.transform_keys(&:to_s) : {}

      @readable = ReadableStream.new(window)
      controller = TransformStreamDefaultController.new(@readable)

      @writable = WritableStream.new(
        window,
        {
          "write" => proc do |chunk|
            if t["transform"].respond_to?(:__js_call__)
              t["transform"].__js_call__("call", [chunk, controller])
            elsif t["transform"].respond_to?(:call)
              t["transform"].call(chunk, controller)
            else
              controller.enqueue(chunk)
            end
          end,
          "close" => proc { @readable.__close__ },
          "abort" => proc { |reason| @readable.__error__(reason) }
        }
      )

      if t["start"]
        if t["start"].respond_to?(:__js_call__)
          t["start"].__js_call__("call", [controller])
        elsif t["start"].respond_to?(:call)
          t["start"].call(controller)
        end
      end
    end

    def __js_get__(key)
      case key
      when "readable"
        @readable
      when "writable"
        @writable
      end
    end
  end

  class TransformStreamDefaultController
    def initialize(readable)
      @readable = readable
    end

    def enqueue(chunk)
      @readable.__enqueue__(chunk)
    end

    def terminate
      @readable.__close__
    end

    def error(reason)
      @readable.__error__(reason)
    end

    def __js_call__(method, args)
      case method
      when "enqueue"
        enqueue(args[0])
      when "terminate"
        terminate
      when "error"
        error(args[0])
      end
    end
  end
end
