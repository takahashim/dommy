# frozen_string_literal: true

module Dommy
  # `PerformanceObserver` — stub. Same observe/disconnect shape, with
  # `__test_trigger__` for tests.
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

    def __test_trigger__(entries)
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
