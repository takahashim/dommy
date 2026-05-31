# frozen_string_literal: true

module Dommy
  # `FileReader` — reads `Blob` / `File` instances into Strings, byte
  # arrays, or data URLs. Asynchronous reads schedule a microtask that
  # fires `load` + `loadend`; sync access (via `result` after the
  # microtask drain) mirrors browser behavior.
  #
  # Spec: https://w3c.github.io/FileAPI/#APIASynch
  class FileReader
    include EventTarget

    EMPTY = 0
    LOADING = 1
    DONE = 2

    INLINE_HANDLERS = %w[loadstart progress load loadend abort error].freeze

    attr_reader :ready_state, :result, :error

    def initialize(window)
      @window = window
      @ready_state = EMPTY
      @result = nil
      @error = nil
      @inline_handlers = {}
      @aborted = false
      @generation = 0
    end

    def read_as_text(blob, _encoding = "utf-8")
      schedule_read(blob) { |raw| raw.dup.force_encoding("UTF-8") }
    end

    alias readAsText read_as_text

    def read_as_data_url(blob)
      schedule_read(blob) do |raw|
        mime = blob.respond_to?(:type) ? blob.type.to_s : ""
        mime = "application/octet-stream" if mime.empty?
        "data:#{mime};base64,#{[raw].pack("m0")}"
      end
    end

    alias readAsDataURL read_as_data_url

    def read_as_array_buffer(blob)
      # readAsArrayBuffer's result is an ArrayBuffer — cross it as a bare one.
      schedule_read(blob) { |raw| Bridge::ArrayBuffer.new(raw.bytes) }
    end

    alias readAsArrayBuffer read_as_array_buffer

    def read_as_binary_string(blob)
      schedule_read(blob) { |raw| raw.dup.force_encoding("ASCII-8BIT") }
    end

    alias readAsBinaryString read_as_binary_string

    def abort
      return if @ready_state != LOADING

      @aborted = true
      @generation += 1
      @ready_state = DONE
      @result = nil
      dispatch_event(Event.new("abort"))
      dispatch_event(Event.new("loadend"))
      nil
    end

    def __js_get__(key)
      case key
      when "readyState"
        @ready_state
      when "result"
        @result
      when "error"
        @error
      when "EMPTY"
        EMPTY
      when "LOADING"
        LOADING
      when "DONE"
        DONE
      else
        @inline_handlers[inline_event_for(key)]
      end
    end

    def __js_set__(key, value)
      event = inline_event_for(key)
      return Bridge::UNHANDLED unless event

      set_inline_handler(event, value)
      nil
    end

    include Bridge::Methods
    js_methods %w[
      readAsText readAsDataURL readAsArrayBuffer readAsBinaryString abort addEventListener
      removeEventListener dispatchEvent
    ]
    def __js_call__(method, args)
      case method
      when "readAsText"
        read_as_text(args[0], args[1])
      when "readAsDataURL"
        read_as_data_url(args[0])
      when "readAsArrayBuffer"
        read_as_array_buffer(args[0])
      when "readAsBinaryString"
        read_as_binary_string(args[0])
      when "abort"
        abort
      when "addEventListener"
        add_event_listener(args[0], args[1], args[2])
      when "removeEventListener"
        remove_event_listener(args[0], args[1], args[2])
      when "dispatchEvent"
        dispatch_event(args[0])
      end
    end

    def __internal_event_parent__
      nil
    end

    private

    def schedule_read(blob, &decoder)
      @ready_state = LOADING
      @result = nil
      @aborted = false
      @generation += 1
      gen = @generation
      dispatch_event(Event.new("loadstart"))

      @window.scheduler.queue_microtask(
        proc do
          next unless @generation == gen && !@aborted

          raw = extract_raw(blob)
          @result = decoder.call(raw)
          @ready_state = DONE
          dispatch_event(Event.new("load"))
          dispatch_event(Event.new("loadend"))
        end
      )

      nil
    end

    # Returns the blob's raw bytes as a binary String.
    def extract_raw(blob)
      if blob.respond_to?(:__dommy_bytes__)
        blob.__dommy_bytes__.to_s
      else
        blob.to_s
      end
    end

    INLINE_EVENT_MAP = INLINE_HANDLERS
      .each_with_object({}) do |name, h|
        h["on#{name}"] = name
      end
      .freeze

    def inline_event_for(key)
      INLINE_EVENT_MAP[key.to_s]
    end

    def set_inline_handler(event, handler)
      previous = @inline_handlers[event]
      remove_event_listener(event, previous) if previous
      if handler.nil?
        @inline_handlers.delete(event)
      else
        add_event_listener(event, handler)
        @inline_handlers[event] = handler
      end
    end
  end
end
