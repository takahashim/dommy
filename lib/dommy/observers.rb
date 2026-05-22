# frozen_string_literal: true

module Dommy
  # `IntersectionObserver` — stub for the viewport-intersection API.
  # Dommy has no layout engine, so callbacks never fire automatically.
  # Tests can drive callbacks explicitly via `__trigger__(entries)`.
  #
  # Spec: https://w3c.github.io/IntersectionObserver/
  class IntersectionObserver
    include Internal::ObservableCallback

    attr_reader :callback, :root, :root_margin, :thresholds

    def initialize(callback, options = nil)
      @callback = callback
      opts = options.is_a?(Hash) ? options : {}
      @root = opts["root"] || opts[:root]
      @root_margin = (opts["rootMargin"] || opts[:rootMargin] || "0px").to_s
      raw_thresholds = opts["threshold"] || opts[:threshold] || 0
      @thresholds = Array(raw_thresholds).map(&:to_f).sort.freeze
      @targets = []
    end

    def observe(target)
      @targets << target unless @targets.include?(target)
      nil
    end

    def unobserve(target)
      @targets.delete(target)
      nil
    end

    def disconnect
      @targets.clear
      nil
    end

    def take_records
      # No queued records in stub mode.
      []
    end

    alias takeRecords take_records

    # Currently-observed targets. Useful for tests that want to assert
    # "the controller registered the right elements".
    def observed_targets
      @targets.dup
    end

    # Test seam: invoke the callback with a synthetic entries list.
    # Each entry is whatever shape the test wants (usually a Hash).
    def __trigger__(entries)
      invoke_callback(entries)
    end

    def __js_get__(key)
      case key
      when "root"
        @root
      when "rootMargin"
        @root_margin
      when "thresholds"
        @thresholds
      end
    end

    def __js_call__(method, args)
      case method
      when "observe"
        observe(args[0])
      when "unobserve"
        unobserve(args[0])
      when "disconnect"
        disconnect
      when "takeRecords"
        take_records
      end
    end
  end

  # `ResizeObserver` — stub for the element-resize API. Same shape as
  # IntersectionObserver: observe / unobserve / disconnect, plus
  # `__trigger__` for tests to drive callbacks.
  #
  # Spec: https://drafts.csswg.org/resize-observer/
  class ResizeObserver
    include Internal::ObservableCallback

    attr_reader :callback

    def initialize(callback)
      @callback = callback
      @targets = []
    end

    def observe(target, _options = nil)
      @targets << target unless @targets.include?(target)
      nil
    end

    def unobserve(target)
      @targets.delete(target)
      nil
    end

    def disconnect
      @targets.clear
      nil
    end

    def observed_targets
      @targets.dup
    end

    def __trigger__(entries)
      invoke_callback(entries)
    end

    def __js_call__(method, args)
      case method
      when "observe"
        observe(args[0], args[1])
      when "unobserve"
        unobserve(args[0])
      when "disconnect"
        disconnect
      end
    end
  end

  # `PerformanceObserver` — stub. Same observe/disconnect shape, with
  # `__trigger__` for tests.
  #
  # Spec: https://w3c.github.io/performance-timeline/
  class PerformanceObserver
    include Internal::ObservableCallback

    attr_reader :callback

    def initialize(callback)
      @callback = callback
      @entry_types = []
    end

    def observe(options = nil)
      opts = options.is_a?(Hash) ? options : {}
      types = opts["entryTypes"] || opts[:entryTypes] || [opts["type"] || opts[:type]].compact
      @entry_types = Array(types).map(&:to_s)
      nil
    end

    def disconnect
      @entry_types = []
      nil
    end

    def take_records
      []
    end

    alias takeRecords take_records

    def entry_types
      @entry_types.dup
    end

    def __trigger__(entries)
      invoke_callback(entries)
    end

    def __js_call__(method, args)
      case method
      when "observe"
        observe(args[0])
      when "disconnect"
        disconnect
      when "takeRecords"
        take_records
      end
    end
  end
end
