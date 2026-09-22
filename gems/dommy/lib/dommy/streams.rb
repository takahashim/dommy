# frozen_string_literal: true

module Dommy
  # The Streams Standard: `ReadableStream`, `WritableStream` and
  # `TransformStream`, with the queuing, backpressure and error propagation
  # the spec gives them. A readable pulls from its underlying source while
  # its queue is below the high water mark; a writable runs one sink write at
  # a time and holds `writer.ready` back while its queue is full; a transform
  # lets a write through only when its readable side has been read. `pipeTo`
  # and `pipeThrough` carry chunks, closure and errors across.
  #
  # Every callback (an underlying source, sink or transformer, from JS or a
  # Ruby proc) may return a promise; the streams wait for it. Every error is
  # the value the callback threw, or a TypeError the spec names.
  #
  # Spec: https://streams.spec.whatwg.org/
  module Streams
    # What a read asks for: the steps to run with the next chunk, at the
    # close, or on an error. The reader's `read()` wraps these in a promise;
    # a pipe runs them directly, so a chunk read while the stream closes is
    # still written before the close is acted on.
    ReadRequest = Struct.new(:chunk_steps, :close_steps, :error_steps)

    module_function

    # An options or strategy dictionary as a String-keyed Hash.
    def dictionary(value)
      value.is_a?(Hash) ? value.transform_keys(&:to_s) : {}
    end

    # Call `callback` (a JS function or a Ruby callable) with `args` and return
    # a promise for what it returns: a returned promise is adopted, a thrown
    # value or raised error rejects.
    def invoke(window, callback, *args)
      return PromiseValue.resolve(window, nil) if callback.nil?

      result = if callback.respond_to?(:__js_invoke__)
        callback.__js_invoke__(args, raising: true)
      else
        CallableInvoker.invoke(callback, *args)
      end
      to_promise(window, result)
    rescue Bridge::ThrowValue => e
      PromiseValue.reject(window, e.value)
    rescue StandardError => e
      PromiseValue.reject(window, e)
    end

    def to_promise(window, value)
      return value if value.is_a?(PromiseValue)
      return PromiseValue.resolve(window, value) unless thenable?(value)

      promise = PromiseValue.new(window)
      value.__js_call__("then", [proc { |v| promise.fulfill(v); nil }, proc { |r| promise.reject(r); nil }])
      promise
    end

    # A bridged JS object with a callable `then`.
    def thenable?(value)
      return false unless value.respond_to?(:__js_get__) && value.respond_to?(:__js_call__)

      then_method = value.__js_get__("then")
      then_method.respond_to?(:__js_call__) || then_method.respond_to?(:call)
    end

    # Run `on_fulfilled` / `on_rejected` when `promise` settles. Both are
    # always attached, so nothing here counts as an unhandled rejection.
    def on_settled(promise, on_fulfilled, on_rejected)
      promise.__js_call__("then", [
        proc { |value| on_fulfilled.call(value); nil },
        proc { |reason| on_rejected.call(reason); nil }
      ])
    end

    def truthy?(value)
      return false if value.nil? || value == false || value == 0 || value == ""
      return false if value.equal?(Bridge::UNDEFINED)

      true
    end

    # The high water mark of a strategy dictionary, `default` when absent.
    def high_water_mark(strategy, default)
      value = strategy["highWaterMark"]
      return default if value.nil? || value.equal?(Bridge::UNDEFINED)

      number = value.is_a?(Numeric) ? value.to_f : Float(value.to_s, exception: false)
      raise Bridge::RangeError, "Invalid highWaterMark" if number.nil? || number.nan? || number.negative?

      number
    end
  end

  # A queue of chunks with the size each one was given, for both kinds of
  # controller.
  #
  # Spec: https://streams.spec.whatwg.org/#queue-with-sizes
  class StreamQueue
    attr_reader :total_size

    def initialize
      @entries = []
      @total_size = 0.0
    end

    def empty?
      @entries.empty?
    end

    def push(value, size)
      @entries << [value, size]
      @total_size += size
    end

    def peek
      @entries.first&.first
    end

    def shift
      return nil if @entries.empty?

      value, size = @entries.shift
      @total_size -= size
      @total_size = 0.0 if @total_size.negative?
      value
    end

    def clear
      @entries.clear
      @total_size = 0.0
    end
  end

  # `new CountQueuingStrategy({highWaterMark})`: every chunk counts one.
  class CountQueuingStrategy
    def initialize(init)
      @high_water_mark = Streams.dictionary(init)["highWaterMark"]
    end

    def __js_get__(key)
      case key
      when "highWaterMark" then @high_water_mark
      when "size" then proc { |_chunk| 1 }
      else Bridge::ABSENT
      end
    end

    def to_h
      {"highWaterMark" => @high_water_mark, "size" => proc { |_chunk| 1 }}
    end
  end

  # `new ByteLengthQueuingStrategy({highWaterMark})`: a chunk counts its bytes.
  class ByteLengthQueuingStrategy
    def initialize(init)
      @high_water_mark = Streams.dictionary(init)["highWaterMark"]
    end

    def self.byte_length(chunk)
      case chunk
      when Bridge::Bytes then chunk.to_a.length
      when String then chunk.bytesize
      when Array then chunk.length
      else
        length = chunk.respond_to?(:__js_get__) ? chunk.__js_get__("byteLength") : nil
        length.is_a?(Numeric) ? length : 0
      end
    end

    def __js_get__(key)
      case key
      when "highWaterMark" then @high_water_mark
      when "size" then proc { |chunk| ByteLengthQueuingStrategy.byte_length(chunk) }
      else Bridge::ABSENT
      end
    end

    def to_h
      {"highWaterMark" => @high_water_mark, "size" => proc { |chunk| ByteLengthQueuingStrategy.byte_length(chunk) }}
    end
  end

  # `ReadableStream` — chunks from an underlying source, read through a
  # reader or piped into a writable.
  #
  # Spec: https://streams.spec.whatwg.org/#rs-class
  class ReadableStream
    attr_reader :state, :stored_error, :controller

    def initialize(window, underlying_source = nil, strategy = nil)
      @window = window
      @state = :readable
      @stored_error = nil
      @reader = nil
      @disturbed = false
      @read_requests = []
      strategy = strategy.respond_to?(:to_h) && !strategy.is_a?(Hash) ? strategy.to_h : Streams.dictionary(strategy)
      source = Streams.dictionary(underlying_source)
      @controller = ReadableStreamDefaultController.new(self, window, source,
                                                        Streams.high_water_mark(strategy, 1), strategy["size"])
      @controller.__internal_start__
    end

    def locked
      !@reader.nil?
    end

    def get_reader
      raise Bridge::TypeError, "ReadableStream is locked" if locked

      @reader = ReadableStreamDefaultReader.new(self, @window)
    end

    alias getReader get_reader

    # Spec: https://streams.spec.whatwg.org/#rs-cancel
    def cancel(reason = nil)
      return PromiseValue.reject(@window, Bridge::TypeError.new("ReadableStream is locked")) if locked

      __internal_cancel__(reason)
    end

    # Spec: https://streams.spec.whatwg.org/#rs-pipe-to
    def pipe_to(destination, options = nil)
      options = Streams.dictionary(options)
      unless destination.is_a?(WritableStream)
        return PromiseValue.reject(@window, Bridge::TypeError.new("pipeTo needs a WritableStream"))
      end
      return PromiseValue.reject(@window, Bridge::TypeError.new("ReadableStream is locked")) if locked
      return PromiseValue.reject(@window, Bridge::TypeError.new("WritableStream is locked")) if destination.locked

      StreamPipe.new(@window, self, destination, options).run
    end

    alias pipeTo pipe_to

    # Spec: https://streams.spec.whatwg.org/#rs-pipe-through
    def pipe_through(transform, options = nil)
      pair = transform.is_a?(Hash) ? transform.transform_keys(&:to_s) : transform
      readable = pair.is_a?(Hash) ? pair["readable"] : pair.readable
      writable = pair.is_a?(Hash) ? pair["writable"] : pair.writable
      unless readable.is_a?(ReadableStream) && writable.is_a?(WritableStream)
        raise Bridge::TypeError, "pipeThrough needs a readable and a writable"
      end
      raise Bridge::TypeError, "ReadableStream is locked" if locked
      raise Bridge::TypeError, "WritableStream is locked" if writable.locked

      pipe_to(writable, options)
      readable
    end

    alias pipeThrough pipe_through

    # Two streams that each get every chunk; the source is read as either
    # branch pulls, and cancelled once both branches are.
    #
    # Spec: https://streams.spec.whatwg.org/#rs-tee
    def tee
      raise Bridge::TypeError, "ReadableStream is locked" if locked

      StreamTee.new(@window, self).branches
    end

    # ---- what fetch and the transform streams reach in through -----------

    def __internal_enqueue__(chunk)
      @controller.enqueue(chunk)
    end

    def __internal_close__
      @controller.close if @controller.can_close_or_enqueue?
    end

    def __internal_error__(reason)
      @controller.error(reason)
    end

    # The chunks queued right now, taken out. For tests and body readers that
    # want the whole thing at once.
    def __internal_drain__
      out = []
      out << @controller.__internal_dequeue__ until @controller.queue_empty?
      out
    end

    def __internal_cancel__(reason)
      @disturbed = true
      return PromiseValue.resolve(@window, nil) if @state == :closed
      return PromiseValue.reject(@window, @stored_error) if @state == :errored

      __internal_close_stream__
      result = PromiseValue.new(@window)
      Streams.on_settled(@controller.cancel_steps(reason), proc { result.fulfill(nil) }, proc { |r| result.reject(r) })
      result
    end

    def __internal_read__(request)
      @disturbed = true
      case @state
      when :closed then request.close_steps.call
      when :errored then request.error_steps.call(@stored_error)
      else @controller.pull_steps(request)
      end
    end

    def __internal_add_read_request__(request)
      @read_requests << request
    end

    def __internal_read_requests__
      @read_requests
    end

    def __internal_close_stream__
      return unless @state == :readable

      @state = :closed
      requests = @read_requests
      @read_requests = []
      requests.each { |request| request.close_steps.call }
      @reader&.__internal_stream_closed__
    end

    def __internal_error_stream__(reason)
      return unless @state == :readable

      @state = :errored
      @stored_error = reason
      requests = @read_requests
      @read_requests = []
      requests.each { |request| request.error_steps.call(reason) }
      @reader&.__internal_stream_errored__(reason)
    end

    def __internal_release_reader__
      @reader = nil
    end

    def disturbed?
      @disturbed
    end

    def __js_get__(key)
      key == "locked" ? locked : Bridge::ABSENT
    end

    include Bridge::Methods
    js_methods %w[getReader cancel pipeTo pipeThrough tee]
    def __js_call__(method, args)
      case method
      when "getReader" then get_reader
      when "cancel" then cancel(args[0])
      when "pipeTo" then pipe_to(args[0], args[1])
      when "pipeThrough" then pipe_through(args[0], args[1])
      when "tee" then tee
      end
    end

    class Error < StandardError
    end
  end

  # The controller an underlying source's `start` and `pull` receive: the
  # queue, the pulling, and the closing and erroring of the stream.
  #
  # Spec: https://streams.spec.whatwg.org/#rs-default-controller-class
  class ReadableStreamDefaultController
    def initialize(stream, window, source, high_water_mark, size_algorithm)
      @stream = stream
      @window = window
      @queue = StreamQueue.new
      @high_water_mark = high_water_mark
      @size_algorithm = size_algorithm
      @start_algorithm = source["start"]
      @pull_algorithm = source["pull"]
      @cancel_algorithm = source["cancel"]
      @started = false
      @pulling = false
      @pull_again = false
      @close_requested = false
    end

    def desired_size
      case @stream.state
      when :errored then nil
      when :closed then 0
      else @high_water_mark - @queue.total_size
      end
    end

    alias desiredSize desired_size

    def can_close_or_enqueue?
      !@close_requested && @stream.state == :readable
    end

    def queue_empty?
      @queue.empty?
    end

    # Spec: https://streams.spec.whatwg.org/#rs-default-controller-enqueue
    def enqueue(chunk)
      raise Bridge::TypeError, "The stream is not in a state that permits enqueue" unless can_close_or_enqueue?

      if @stream.locked && !@stream.__internal_read_requests__.empty?
        @stream.__internal_read_requests__.shift.chunk_steps.call(chunk)
      else
        size = chunk_size(chunk)
        @queue.push(chunk, size)
      end
      call_pull_if_needed
      nil
    end

    # Spec: https://streams.spec.whatwg.org/#rs-default-controller-close
    def close
      raise Bridge::TypeError, "The stream is not in a state that permits close" unless can_close_or_enqueue?

      @close_requested = true
      @stream.__internal_close_stream__ if @queue.empty?
      nil
    end

    # Spec: https://streams.spec.whatwg.org/#rs-default-controller-error
    def error(reason = nil)
      return unless @stream.state == :readable

      @queue.clear
      clear_algorithms
      @stream.__internal_error_stream__(reason)
      nil
    end

    def cancel_steps(reason)
      @queue.clear
      algorithm = @cancel_algorithm
      clear_algorithms
      Streams.invoke(@window, algorithm, reason)
    end

    # A read: the next queued chunk, or a request that the next enqueue
    # answers.
    def pull_steps(request)
      if @queue.empty?
        @stream.__internal_add_read_request__(request)
        call_pull_if_needed
        return
      end

      chunk = @queue.shift
      if @close_requested && @queue.empty?
        clear_algorithms
        @stream.__internal_close_stream__
      else
        call_pull_if_needed
      end
      request.chunk_steps.call(chunk)
    end

    def __internal_dequeue__
      @queue.shift
    end

    def __internal_start__
      Streams.on_settled(
        Streams.invoke(@window, @start_algorithm, self),
        proc do
          @started = true
          call_pull_if_needed
        end,
        proc { |reason| error(reason) }
      )
    end

    def __js_get__(key)
      key == "desiredSize" ? desired_size : Bridge::ABSENT
    end

    include Bridge::Methods
    js_methods %w[enqueue close error]
    def __js_call__(method, args)
      case method
      when "enqueue" then enqueue(args[0])
      when "close" then close
      when "error" then error(args[0])
      end
    end

    private

    def chunk_size(chunk)
      return 1 if @size_algorithm.nil?

      size = CallableInvoker.invoke(@size_algorithm, chunk)
      size = size.is_a?(Numeric) ? size.to_f : Float(size.to_s, exception: false)
      if size.nil? || size.nan? || size.negative? || size.infinite?
        raise Bridge::RangeError, "The chunk size is not a valid size"
      end

      size
    rescue Bridge::ThrowValue, StandardError => e
      reason = e.is_a?(Bridge::ThrowValue) ? e.value : e
      error(reason)
      raise e
    end

    def should_call_pull?
      return false unless can_close_or_enqueue? && @started
      return true if @stream.locked && !@stream.__internal_read_requests__.empty?

      desired_size.positive?
    end

    def call_pull_if_needed
      return unless should_call_pull?

      if @pulling
        @pull_again = true
        return
      end

      @pulling = true
      Streams.on_settled(
        Streams.invoke(@window, @pull_algorithm, self),
        proc do
          @pulling = false
          if @pull_again
            @pull_again = false
            call_pull_if_needed
          end
        end,
        proc { |reason| error(reason) }
      )
    end

    def clear_algorithms
      @pull_algorithm = nil
      @cancel_algorithm = nil
      @size_algorithm = nil
    end
  end

  # The reader `getReader()` hands out: `read()` promises, a `closed` promise,
  # and the lock it holds on the stream until `releaseLock()`.
  #
  # Spec: https://streams.spec.whatwg.org/#default-reader-class
  class ReadableStreamDefaultReader
    def initialize(stream, window)
      @stream = stream
      @window = window
      @closed = PromiseValue.new(window)
      case stream.state
      when :closed then @closed.fulfill(nil)
      when :errored then @closed.reject(stream.stored_error)
      end
    end

    attr_reader :closed

    def read
      promise = PromiseValue.new(@window)
      __internal_read_with__(Streams::ReadRequest.new(
        proc { |chunk| promise.fulfill({"value" => chunk, "done" => false}) },
        proc { promise.fulfill({"value" => Bridge::UNDEFINED, "done" => true}) },
        proc { |reason| promise.reject(reason) }
      ))
      promise
    end

    # A read whose steps run as soon as the stream has an answer, with no
    # promise in between.
    def __internal_read_with__(request)
      return request.error_steps.call(Bridge::TypeError.new("The reader was released")) unless @stream

      @stream.__internal_read__(request)
    end

    # Spec: https://streams.spec.whatwg.org/#default-reader-release-lock
    def release_lock
      return unless @stream

      stream = @stream
      @stream = nil
      stream.__internal_release_reader__
      released = Bridge::TypeError.new("The reader was released")
      @closed.reject(released)
      requests = stream.__internal_read_requests__.dup
      stream.__internal_read_requests__.clear
      requests.each { |request| request.error_steps.call(released) }
      nil
    end

    alias releaseLock release_lock

    def cancel(reason = nil)
      return PromiseValue.reject(@window, Bridge::TypeError.new("The reader was released")) unless @stream

      @stream.__internal_cancel__(reason)
    end

    def __internal_stream_closed__
      @closed.fulfill(nil)
    end

    def __internal_stream_errored__(reason)
      @closed.reject(reason)
    end

    def __js_get__(key)
      key == "closed" ? @closed : Bridge::ABSENT
    end

    include Bridge::Methods
    js_methods %w[read releaseLock cancel]
    def __js_call__(method, args)
      case method
      when "read" then read
      when "releaseLock" then release_lock
      when "cancel" then cancel(args[0])
      end
    end
  end

  # `WritableStream` — chunks into an underlying sink, one write at a time,
  # through a writer.
  #
  # Spec: https://streams.spec.whatwg.org/#ws-class
  class WritableStream
    attr_reader :state, :stored_error

    CLOSE_SENTINEL = Object.new
    private_constant :CLOSE_SENTINEL

    def initialize(window, underlying_sink = nil, strategy = nil)
      @window = window
      @state = :writable
      @stored_error = nil
      @writer = nil
      @queue = StreamQueue.new
      @write_requests = []
      @close_request = nil
      @in_flight_write = nil
      @in_flight_close = nil
      @started = false
      @backpressure = false
      strategy = strategy.respond_to?(:to_h) && !strategy.is_a?(Hash) ? strategy.to_h : Streams.dictionary(strategy)
      @high_water_mark = Streams.high_water_mark(strategy, 1)
      @size_algorithm = strategy["size"]
      sink = Streams.dictionary(underlying_sink)
      @write_algorithm = sink["write"]
      @close_algorithm = sink["close"]
      @abort_algorithm = sink["abort"]
      @controller = WritableStreamDefaultController.new(self)
      update_backpressure
      Streams.on_settled(
        Streams.invoke(@window, sink["start"], @controller),
        proc do
          @started = true
          advance_queue_if_needed
        end,
        proc { |reason| @started = true; __internal_error__(reason) }
      )
    end

    def locked
      !@writer.nil?
    end

    def get_writer
      raise Bridge::TypeError, "WritableStream is locked" if locked

      @writer = WritableStreamDefaultWriter.new(self, @window)
    end

    alias getWriter get_writer

    def close
      return PromiseValue.reject(@window, Bridge::TypeError.new("WritableStream is locked")) if locked

      __internal_close__
    end

    def abort(reason = nil)
      return PromiseValue.reject(@window, Bridge::TypeError.new("WritableStream is locked")) if locked

      __internal_abort__(reason)
    end

    def desired_size
      case @state
      when :errored then nil
      when :closed then 0
      else @high_water_mark - @queue.total_size
      end
    end

    def close_queued_or_in_flight?
      !@close_request.nil? || !@in_flight_close.nil?
    end

    def backpressure?
      @backpressure
    end

    # ---- what the writer and the transform streams reach in through ------

    def __internal_write__(chunk)
      case @state
      when :errored then return PromiseValue.reject(@window, @stored_error)
      when :closed then return PromiseValue.reject(@window, Bridge::TypeError.new("The stream is closed"))
      end
      if close_queued_or_in_flight?
        return PromiseValue.reject(@window, Bridge::TypeError.new("The stream is closing"))
      end

      size = chunk_size(chunk)
      request = PromiseValue.new(@window)
      @write_requests << request
      @queue.push(chunk, size)
      update_backpressure
      advance_queue_if_needed
      request
    rescue Bridge::ThrowValue, StandardError => e
      reason = e.is_a?(Bridge::ThrowValue) ? e.value : e
      __internal_error__(reason)
      PromiseValue.reject(@window, reason)
    end

    # Spec: https://streams.spec.whatwg.org/#writable-stream-close
    def __internal_close__
      case @state
      when :errored then return PromiseValue.reject(@window, @stored_error)
      when :closed then return PromiseValue.reject(@window, Bridge::TypeError.new("The stream is already closed"))
      end
      if close_queued_or_in_flight?
        return PromiseValue.reject(@window, Bridge::TypeError.new("The stream is already closing"))
      end

      request = PromiseValue.new(@window)
      @close_request = request
      @queue.push(CLOSE_SENTINEL, 0)
      @writer&.__internal_ready_resolved__ if @backpressure
      advance_queue_if_needed # may take the request in flight right away
      request
    end

    # Spec: https://streams.spec.whatwg.org/#writable-stream-abort
    def __internal_abort__(reason)
      return PromiseValue.resolve(@window, nil) if @state == :closed || @state == :errored

      algorithm = @abort_algorithm
      __internal_error__(reason)
      result = PromiseValue.new(@window)
      Streams.on_settled(Streams.invoke(@window, algorithm, reason), proc { result.fulfill(nil) }, proc { |r| result.reject(r) })
      result
    end

    # Errors the stream: every pending write and close rejects, and the
    # writer's `closed` and `ready` with them.
    def __internal_error__(reason)
      return unless @state == :writable

      @state = :errored
      @stored_error = reason
      @queue.clear
      @write_algorithm = nil
      @close_algorithm = nil
      @abort_algorithm = nil
      requests = @write_requests
      @write_requests = []
      requests.each { |request| request.reject(reason) }
      @in_flight_write&.reject(reason)
      @in_flight_write = nil
      @close_request&.reject(reason)
      @close_request = nil
      @in_flight_close&.reject(reason)
      @in_flight_close = nil
      @writer&.__internal_stream_errored__(reason)
    end

    def __internal_release_writer__
      @writer = nil
    end

    def __js_get__(key)
      key == "locked" ? locked : Bridge::ABSENT
    end

    include Bridge::Methods
    js_methods %w[getWriter close abort]
    def __js_call__(method, args)
      case method
      when "getWriter" then get_writer
      when "close" then close
      when "abort" then abort(args[0])
      end
    end

    class Error < StandardError
    end

    private

    def chunk_size(chunk)
      return 1 if @size_algorithm.nil?

      size = CallableInvoker.invoke(@size_algorithm, chunk)
      size = size.is_a?(Numeric) ? size.to_f : Float(size.to_s, exception: false)
      if size.nil? || size.nan? || size.negative? || size.infinite?
        raise Bridge::RangeError, "The chunk size is not a valid size"
      end

      size
    end

    def update_backpressure
      backpressure = @state == :writable && desired_size <= 0
      return if backpressure == @backpressure

      @backpressure = backpressure
      @writer&.__internal_backpressure_changed__(backpressure)
    end

    def advance_queue_if_needed
      return unless @started && @in_flight_write.nil? && @in_flight_close.nil?
      return unless @state == :writable
      return if @queue.empty?

      value = @queue.peek
      if value.equal?(CLOSE_SENTINEL)
        process_close
      else
        process_write(value)
      end
    end

    def process_write(chunk)
      @in_flight_write = @write_requests.shift
      Streams.on_settled(
        Streams.invoke(@window, @write_algorithm, chunk, @controller),
        proc do
          request = @in_flight_write
          @in_flight_write = nil
          next if request.nil? # the stream was errored or aborted meanwhile

          @queue.shift
          request.fulfill(nil)
          update_backpressure
          advance_queue_if_needed
        end,
        proc do |reason|
          request = @in_flight_write
          @in_flight_write = nil
          request&.reject(reason)
          __internal_error__(reason)
        end
      )
    end

    def process_close
      @in_flight_close = @close_request
      @close_request = nil
      @queue.shift
      Streams.on_settled(
        Streams.invoke(@window, @close_algorithm),
        proc do
          request = @in_flight_close
          @in_flight_close = nil
          next if request.nil?

          @state = :closed
          request.fulfill(nil)
          @writer&.__internal_stream_closed__
        end,
        proc do |reason|
          request = @in_flight_close
          @in_flight_close = nil
          request&.reject(reason)
          __internal_error__(reason)
        end
      )
    end
  end

  # The controller an underlying sink's `start` and `write` receive.
  #
  # Spec: https://streams.spec.whatwg.org/#ws-default-controller-class
  class WritableStreamDefaultController
    def initialize(stream)
      @stream = stream
    end

    def error(reason = nil)
      @stream.__internal_error__(reason)
      nil
    end

    include Bridge::Methods
    js_methods %w[error]
    def __js_call__(method, args)
      case method
      when "error" then error(args[0])
      end
    end
  end

  # The writer `getWriter()` hands out: `write()` promises that settle when
  # the sink took the chunk, `ready` that waits out backpressure, `closed`.
  #
  # Spec: https://streams.spec.whatwg.org/#default-writer-class
  class WritableStreamDefaultWriter
    def initialize(stream, window)
      @stream = stream
      @window = window
      @closed = PromiseValue.new(window)
      @ready = PromiseValue.new(window)
      case stream.state
      when :closed
        @closed.fulfill(nil)
        @ready.fulfill(nil)
      when :errored
        @closed.reject(stream.stored_error)
        @ready.reject(stream.stored_error)
      else
        @ready.fulfill(nil) unless stream.backpressure?
        @ready.fulfill(nil) if stream.close_queued_or_in_flight?
      end
    end

    attr_reader :closed, :ready

    def desired_size
      raise Bridge::TypeError, "The writer was released" unless @stream

      @stream.desired_size
    end

    alias desiredSize desired_size

    def write(chunk)
      return PromiseValue.reject(@window, Bridge::TypeError.new("The writer was released")) unless @stream

      @stream.__internal_write__(chunk)
    end

    def close
      return PromiseValue.reject(@window, Bridge::TypeError.new("The writer was released")) unless @stream

      @stream.__internal_close__
    end

    def abort(reason = nil)
      return PromiseValue.reject(@window, Bridge::TypeError.new("The writer was released")) unless @stream

      @stream.__internal_abort__(reason)
    end

    def release_lock
      return unless @stream

      stream = @stream
      @stream = nil
      stream.__internal_release_writer__
      released = Bridge::TypeError.new("The writer was released")
      @closed.reject(released)
      @ready.reject(released)
      nil
    end

    alias releaseLock release_lock

    def __internal_backpressure_changed__(backpressure)
      if backpressure
        @ready = PromiseValue.new(@window) if @ready.settled?
      else
        @ready.fulfill(nil)
      end
    end

    def __internal_ready_resolved__
      @ready.fulfill(nil)
    end

    def __internal_stream_closed__
      @closed.fulfill(nil)
      @ready.fulfill(nil)
    end

    def __internal_stream_errored__(reason)
      @closed.reject(reason)
      @ready = PromiseValue.new(@window) if @ready.settled?
      @ready.reject(reason)
    end

    def __js_get__(key)
      case key
      when "closed" then @closed
      when "ready" then @ready
      when "desiredSize" then desired_size
      else Bridge::ABSENT
      end
    end

    include Bridge::Methods
    js_methods %w[write close abort releaseLock]
    def __js_call__(method, args)
      case method
      when "write" then write(args[0])
      when "close" then close
      when "abort" then abort(args[0])
      when "releaseLock" then release_lock
      end
    end
  end

  # `TransformStream` — a writable side whose chunks come out of a readable
  # side after `transform`. The readable's high water mark is 0 by default,
  # so a write is only taken once a read has asked for it.
  #
  # Spec: https://streams.spec.whatwg.org/#ts-class
  class TransformStream
    attr_reader :readable, :writable

    def initialize(window, transformer = nil, writable_strategy = nil, readable_strategy = nil)
      @window = window
      transformer = Streams.dictionary(transformer)
      @transform_algorithm = transformer["transform"]
      @flush_algorithm = transformer["flush"]
      @backpressure = nil
      @backpressure_change = nil
      @controller = TransformStreamDefaultController.new(self, window)

      readable_strategy = Streams.dictionary(readable_strategy)
      readable_strategy["highWaterMark"] = 0 unless readable_strategy.key?("highWaterMark")
      @readable = ReadableStream.new(window, {
        "pull" => proc { source_pull },
        "cancel" => proc { |reason| source_cancel(reason) }
      }, readable_strategy)
      @writable = WritableStream.new(window, {
        "write" => proc { |chunk| sink_write(chunk) },
        "close" => proc { sink_close },
        "abort" => proc { |reason| sink_abort(reason) }
      }, writable_strategy)
      set_backpressure(true)

      Streams.on_settled(
        Streams.invoke(window, transformer["start"], @controller),
        proc {},
        proc { |reason| error_both(reason) }
      )
    end

    def readable_controller
      @readable.controller
    end

    # Spec: https://streams.spec.whatwg.org/#transform-stream-default-controller-enqueue
    def __internal_enqueue__(chunk)
      unless readable_controller.can_close_or_enqueue?
        raise Bridge::TypeError, "The readable side is not in a state that permits enqueue"
      end

      begin
        readable_controller.enqueue(chunk)
      rescue Bridge::ThrowValue, StandardError => e
        reason = e.is_a?(Bridge::ThrowValue) ? e.value : e
        @writable.__internal_error__(reason)
        raise Bridge::ThrowValue.new(@readable.stored_error) if e.is_a?(Bridge::ThrowValue)

        raise
      end

      set_backpressure(true) if readable_controller.desired_size <= 0 && !@backpressure
      nil
    end

    def __internal_terminate__
      readable_controller.close if readable_controller.can_close_or_enqueue?
      @writable.__internal_error__(Bridge::TypeError.new("The transform stream was terminated"))
    end

    def error_both(reason)
      readable_controller.error(reason)
      @writable.__internal_error__(reason)
    end

    def __js_get__(key)
      case key
      when "readable" then @readable
      when "writable" then @writable
      else Bridge::ABSENT
      end
    end

    private

    # A write waits while the readable side has not asked for more.
    def sink_write(chunk)
      return perform_transform(chunk) unless @backpressure

      result = PromiseValue.new(@window)
      Streams.on_settled(
        @backpressure_change,
        proc do
          if @writable.state != :writable
            result.reject(@writable.stored_error)
          else
            Streams.on_settled(perform_transform(chunk), proc { result.fulfill(nil) }, proc { |r| result.reject(r) })
          end
        end,
        proc { |reason| result.reject(reason) }
      )
      result
    end

    def perform_transform(chunk)
      promise = if @transform_algorithm
        Streams.invoke(@window, @transform_algorithm, chunk, @controller)
      else
        begin
          __internal_enqueue__(chunk)
          PromiseValue.resolve(@window, nil)
        rescue Bridge::ThrowValue => e
          PromiseValue.reject(@window, e.value)
        rescue StandardError => e
          PromiseValue.reject(@window, e)
        end
      end
      result = PromiseValue.new(@window)
      Streams.on_settled(promise, proc { result.fulfill(nil) }, proc do |reason|
        error_both(reason)
        result.reject(reason)
      end)
      result
    end

    def sink_close
      result = PromiseValue.new(@window)
      Streams.on_settled(
        Streams.invoke(@window, @flush_algorithm, @controller),
        proc do
          readable_controller.close if readable_controller.can_close_or_enqueue?
          result.fulfill(nil)
        end,
        proc do |reason|
          error_both(reason)
          result.reject(reason)
        end
      )
      result
    end

    def sink_abort(reason)
      readable_controller.error(reason)
      PromiseValue.resolve(@window, nil)
    end

    def source_pull
      set_backpressure(false)
      @backpressure_change
    end

    def source_cancel(reason)
      @writable.__internal_error__(reason)
      PromiseValue.resolve(@window, nil)
    end

    def set_backpressure(backpressure)
      @backpressure_change&.fulfill(nil)
      @backpressure_change = PromiseValue.new(@window)
      @backpressure = backpressure
    end
  end

  # The controller a transformer's `start`, `transform` and `flush` receive.
  #
  # Spec: https://streams.spec.whatwg.org/#ts-default-controller-class
  class TransformStreamDefaultController
    def initialize(stream, window)
      @stream = stream
      @window = window
    end

    def desired_size
      @stream.readable_controller.desired_size
    end

    alias desiredSize desired_size

    def enqueue(chunk)
      @stream.__internal_enqueue__(chunk)
    end

    def terminate
      @stream.__internal_terminate__
      nil
    end

    def error(reason = nil)
      @stream.error_both(reason)
      nil
    end

    def __js_get__(key)
      key == "desiredSize" ? desired_size : Bridge::ABSENT
    end

    include Bridge::Methods
    js_methods %w[enqueue terminate error]
    def __js_call__(method, args)
      case method
      when "enqueue" then enqueue(args[0])
      when "terminate" then terminate
      when "error" then error(args[0])
      end
    end
  end

  # One `pipeTo`: reads from the source as the destination's `ready` allows,
  # closes or aborts the destination when the source ends, cancels the source
  # when the destination fails, and releases both locks at the end.
  #
  # Spec: https://streams.spec.whatwg.org/#readable-stream-pipe-to
  class StreamPipe
    def initialize(window, source, destination, options)
      @window = window
      @source = source
      @destination = destination
      @prevent_close = Streams.truthy?(options["preventClose"])
      @prevent_abort = Streams.truthy?(options["preventAbort"])
      @prevent_cancel = Streams.truthy?(options["preventCancel"])
      @promise = PromiseValue.new(window)
      @current_write = nil
      @shutting_down = false
      @finished = false
    end

    def run
      @reader = @source.get_reader
      @writer = @destination.get_writer
      Streams.on_settled(@writer.closed, proc {}, proc { |reason| destination_failed(reason) })
      Streams.on_settled(@reader.closed, proc { source_closed }, proc { |reason| source_failed(reason) })
      step
      @promise
    end

    private

    def step
      return if @shutting_down

      case @destination.state
      when :errored then return destination_failed(@destination.stored_error)
      when :closed then return destination_failed(Bridge::TypeError.new("The destination was closed"))
      end

      Streams.on_settled(
        @writer.ready,
        proc do
          next if @shutting_down

          @reader.__internal_read_with__(Streams::ReadRequest.new(
            proc do |chunk|
              # The write is issued before anything else can react to the
              # stream closing behind this chunk.
              @current_write = @writer.write(chunk)
              Streams.on_settled(@current_write, proc {}, proc {})
              step
            end,
            proc { source_closed },
            proc { |reason| source_failed(reason) }
          ))
        end,
        proc { |reason| destination_failed(reason) }
      )
    end

    # Each shutdown path runs once: the first one to start owns the outcome.
    def shutdown?
      return true if @shutting_down

      @shutting_down = true
      false
    end

    def source_closed
      return if shutdown?

      if @prevent_close
        after_pending_writes { finish(nil) }
      else
        after_pending_writes do
          Streams.on_settled(@writer.close, proc { finish(nil) }, proc { |reason| finish(reason, failed: true) })
        end
      end
    end

    # Every chunk read so far is written before the destination is closed.
    def after_pending_writes(&block)
      return block.call unless @current_write

      Streams.on_settled(@current_write, proc { block.call }, proc { block.call })
    end

    def source_failed(reason)
      return if shutdown?

      if @prevent_abort
        finish(reason, failed: true)
      else
        Streams.on_settled(@writer.abort(reason), proc { finish(reason, failed: true) },
                           proc { |abort_reason| finish(abort_reason, failed: true) })
      end
    end

    def destination_failed(reason)
      return if shutdown?

      if @prevent_cancel
        finish(reason, failed: true)
      else
        Streams.on_settled(@reader.cancel(reason), proc { finish(reason, failed: true) },
                           proc { |cancel_reason| finish(cancel_reason, failed: true) })
      end
    end

    def finish(reason, failed: false)
      return if @finished

      @finished = true
      @reader.release_lock
      @writer.release_lock
      failed ? @promise.reject(reason) : @promise.fulfill(nil)
    end
  end

  # One `tee`: the source's reader feeds two branches, each of which pulls
  # only when it is read, and the source is cancelled once both branches are.
  #
  # Spec: https://streams.spec.whatwg.org/#readable-stream-tee
  class StreamTee
    attr_reader :branches

    def initialize(window, source)
      @window = window
      @reader = source.get_reader
      @reading = false
      @cancelled = [false, false]
      @reasons = [nil, nil]
      @cancel_promise = PromiseValue.new(window)
      @branches = [0, 1].map do |index|
        ReadableStream.new(window, {
          "pull" => proc { pull },
          "cancel" => proc { |reason| cancel_branch(index, reason) }
        })
      end
    end

    private

    def pull
      return PromiseValue.resolve(@window, nil) if @reading

      @reading = true
      @reader.__internal_read_with__(Streams::ReadRequest.new(
        proc do |chunk|
          @reading = false
          @branches.each_with_index do |branch, index|
            branch.__internal_enqueue__(chunk) unless @cancelled[index]
          end
        end,
        proc do
          @reading = false
          @branches.each_with_index { |branch, index| branch.__internal_close__ unless @cancelled[index] }
          @cancel_promise.fulfill(nil) unless @cancelled.all?
        end,
        proc do |reason|
          @reading = false
          @branches.each { |branch| branch.__internal_error__(reason) }
          @cancel_promise.fulfill(nil) unless @cancelled.all?
        end
      ))
      PromiseValue.resolve(@window, nil)
    end

    def cancel_branch(index, reason)
      @cancelled[index] = true
      @reasons[index] = reason
      if @cancelled.all?
        Streams.on_settled(@reader.cancel(@reasons), proc { @cancel_promise.fulfill(nil) },
                           proc { |r| @cancel_promise.reject(r) })
      end
      @cancel_promise
    end
  end
end
