# frozen_string_literal: true

module Dommy
  # `window.performance` — User Timing API (mark / measure) plus a
  # virtual `now` clock backed by the deterministic scheduler.
  #
  # Spec:
  #   - User Timing: https://www.w3.org/TR/user-timing/
  #   - HRT (now):   https://www.w3.org/TR/hr-time/
  class Performance
    def initialize(window)
      @window = window
      @entries = []
    end

    def now
      @window.scheduler.now_ms.to_f
    end

    def mark(name, options = nil)
      start_time = options.is_a?(Hash) && options.key?("startTime") ? options["startTime"].to_f : now
      detail = options.is_a?(Hash) ? options["detail"] : nil
      entry = PerformanceEntry.new(
        name: name.to_s,
        entry_type: "mark",
        start_time: start_time,
        duration: 0.0,
        detail: detail
      )
      @entries << entry
      entry
    end

    def measure(name, start_or_options = nil, end_mark = nil)
      if start_or_options.is_a?(Hash)
        start = resolve_time(start_or_options["start"])
        finish = resolve_time(start_or_options["end"])
      else
        start = resolve_time(start_or_options)
        finish = resolve_time(end_mark)
      end

      start ||= 0.0
      finish ||= now
      entry = PerformanceEntry.new(
        name: name.to_s,
        entry_type: "measure",
        start_time: start,
        duration: finish - start
      )
      @entries << entry
      entry
    end

    def clear_marks(name = nil)
      @entries.reject! { |e| e.entry_type == "mark" && (name.nil? || e.name == name.to_s) }
      nil
    end

    alias clearMarks clear_marks

    def clear_measures(name = nil)
      @entries.reject! { |e| e.entry_type == "measure" && (name.nil? || e.name == name.to_s) }
      nil
    end

    alias clearMeasures clear_measures

    def get_entries
      @entries.dup
    end

    alias getEntries get_entries

    def get_entries_by_name(name, entry_type = nil)
      @entries.select { |e| e.name == name.to_s && (entry_type.nil? || e.entry_type == entry_type.to_s) }
    end

    alias getEntriesByName get_entries_by_name

    def get_entries_by_type(entry_type)
      @entries.select { |e| e.entry_type == entry_type.to_s }
    end

    alias getEntriesByType get_entries_by_type

    def __js_get__(key)
      case key
      when "now"
        now
      when "timeOrigin"
        0.0
      else
        Bridge::ABSENT
      end
    end

    include Bridge::Methods
    js_methods %w[
      now mark measure clearMarks clearMeasures getEntries getEntriesByName getEntriesByType
    ]
    def __js_call__(method, args)
      case method
      when "now"
        now
      when "mark"
        mark(args[0], args[1])
      when "measure"
        measure(args[0], args[1], args[2])
      when "clearMarks"
        clear_marks(args[0])
      when "clearMeasures"
        clear_measures(args[0])
      when "getEntries"
        get_entries
      when "getEntriesByName"
        get_entries_by_name(args[0], args[1])
      when "getEntriesByType"
        get_entries_by_type(args[0])
      end
    end

    private

    # Resolve a `mark name` or numeric timestamp to a `now`-relative time.
    def resolve_time(value)
      return nil if value.nil?
      return value.to_f if value.is_a?(Numeric)

      mark = @entries.reverse.find { |e| e.entry_type == "mark" && e.name == value.to_s }
      mark ? mark.start_time : nil
    end
  end

  # `PerformanceEntry` — common shape for User Timing marks/measures.
  PerformanceEntry = Struct.new(:name, :entry_type, :start_time, :duration, :detail, keyword_init: true) do
    def __js_get__(key)
      case key
      when "name"
        name
      when "entryType"
        entry_type
      when "startTime"
        start_time
      when "duration"
        duration
      when "detail"
        detail
      else
        Bridge::ABSENT
      end
    end
  end
end
