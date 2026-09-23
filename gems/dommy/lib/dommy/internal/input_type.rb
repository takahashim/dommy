# frozen_string_literal: true

require "date"

module Dommy
  module Internal
    # What `<input type=...>` means where the type actually matters: reading the
    # value as a number, writing one back, and the arithmetic `stepUp` does.
    #
    # `<input>` is twenty-odd controls sharing one interface, and that showed up
    # as `case type` in sixteen HTMLInputElement methods — so a new type meant
    # finding all sixteen, and the knowledge about `week` (its epoch is
    # mid-week, so steps measure from 1970-W01) lived three methods away from
    # the code that converts a week string. Here a type is one class.
    #
    # Only the numeric surface lives here. Value sanitization stays on the
    # element, where it reads other attributes (`multiple` for email).
    class InputType
      # The type `name` stands for. An unknown or non-numeric type answers the
      # one that has no numbers, so callers never branch on nil.
      def self.for(name) = REGISTRY.fetch(name.to_s, NON_NUMERIC)

      # Whether valueAsNumber / stepUp / stepDown apply at all.
      def numeric? = true

      # How many of the number's units one step is worth.
      def scale_factor = 1

      # The step a control uses when it declares none.
      def default_step = 1.0

      # Where steps are measured from when `min` gives no base.
      def step_base = 0.0

      # The value string as a number, or NaN when it is not one. `element` is
      # there for the one type that reads other attributes to answer (range).
      def to_number(_text, _element = nil) = ::Float::NAN

      # A number as the value string it writes.
      def from_number(number, element)
        raise DOMException::InvalidStateError,
          "valueAsNumber is not applicable to input type '#{element.type}'"
      end

      # A `min`/`max` attribute as a number, or nil when it is not one. Not
      # to_number: the numeric types accept anything Float() takes here, where
      # the value itself must match the valid-floating-point grammar.
      def boundary(text) = nil

      protected

      def nan_to_nil(number) = number.nan? ? nil : number

      def utc_time_from_ms(ms) = ::Time.at(ms / 1000.0).utc
    end

    # Everything that is not one of the numeric types below: text, checkbox,
    # file, color and the rest. valueAsNumber reads NaN and refuses to be set.
    class NonNumericInputType < InputType
      def numeric? = false
    end

    # `number`, and the base for `range`.
    class NumberInputType < InputType
      VALID_FLOAT = /\A-?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][-+]?\d+)?\z/

      def to_number(text, _element = nil)
        string = text.to_s
        VALID_FLOAT.match?(string) ? (Float(string) rescue ::Float::NAN) : ::Float::NAN
      end

      def from_number(number, _element)
        return "" if number.nan?

        number == number.to_i ? number.to_i.to_s : number.to_s
      end

      def boundary(text) = (Float(text) rescue nil)
    end

    # A range always reads as a number: an unparseable value is the midpoint of
    # its own min and max, which default to 0 and 100.
    class RangeInputType < NumberInputType
      def to_number(text, element = nil)
        number = super
        return number unless element

        low = (Float(element.get_attribute("min").to_s) rescue 0.0)
        high = (Float(element.get_attribute("max").to_s) rescue 100.0)
        number = nil if number.nan?
        number ||= high < low ? low : low + (high - low) / 2.0
        number.clamp(low, high)
      end
    end

    class DateInputType < InputType
      def scale_factor = 86_400_000

      def to_number(text, _element = nil)
        match = /\A(\d{4,})-(\d{2})-(\d{2})\z/.match(text.to_s.strip)
        return ::Float::NAN unless match

        year, month, day = match[1].to_i, match[2].to_i, match[3].to_i
        return ::Float::NAN if year < 1 || !::Date.valid_date?(year, month, day)

        ::Time.utc(year, month, day).to_i * 1000.0
      end

      def from_number(number, _element)
        return "" if number.nan?

        time = utc_time_from_ms(number)
        format("%04d-%02d-%02d", time.year, time.month, time.day)
      rescue ::RangeError, ::ArgumentError, ::FloatDomainError
        ""
      end

      def boundary(text) = nan_to_nil(to_number(text))
    end

    class TimeInputType < InputType
      def scale_factor = 1000
      def default_step = 60.0

      def to_number(text, _element = nil)
        match = /\A(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?\z/.match(text.to_s.strip)
        return ::Float::NAN unless match

        hour, minute, second = match[1].to_i, match[2].to_i, match[3].to_i
        return ::Float::NAN if hour > 23 || minute > 59 || second > 59

        fraction = match[4] ? match[4].ljust(3, "0").to_i : 0
        ((hour * 3600 + minute * 60 + second) * 1000 + fraction).to_f
      end

      def from_number(number, _element)
        return "" if number.nan?

        value = (number % 86_400_000).to_i
        hour = value / 3_600_000
        minute = (value % 3_600_000) / 60_000
        second = (value % 60_000) / 1000
        fraction = value % 1000
        if second.zero? && fraction.zero?
          format("%02d:%02d", hour, minute)
        elsif fraction.zero?
          format("%02d:%02d:%02d", hour, minute, second)
        else
          format("%02d:%02d:%02d.%03d", hour, minute, second, fraction)
        end
      end

      def boundary(text) = nan_to_nil(to_number(text))
    end

    class DatetimeLocalInputType < InputType
      def scale_factor = 1000
      def default_step = 60.0

      def to_number(text, _element = nil)
        # The date/time separator may be "T" or a space (the "parse a local date
        # and time string" algorithm accepts both).
        match = /\A(\d{4,})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?\z/
          .match(text.to_s.strip)
        return ::Float::NAN unless match

        year, month, day = match[1].to_i, match[2].to_i, match[3].to_i
        hour, minute, second = match[4].to_i, match[5].to_i, match[6].to_i
        return ::Float::NAN if year < 1 || !::Date.valid_date?(year, month, day)
        return ::Float::NAN if hour > 23 || minute > 59 || second > 59

        fraction = match[7] ? match[7].ljust(3, "0").to_i : 0
        (::Time.utc(year, month, day, hour, minute, second).to_i * 1000 + fraction).to_f
      end

      def from_number(number, _element)
        return "" if number.nan?

        time = utc_time_from_ms(number)
        return "" if time.year < 1 || time.year > 9999

        base = format("%04d-%02d-%02dT%02d:%02d", time.year, time.month, time.day, time.hour, time.min)
        fraction = (number % 1000).to_i
        if time.sec.zero? && fraction.zero?
          base
        elsif fraction.zero?
          base + format(":%02d", time.sec)
        else
          base + format(":%02d.%03d", time.sec, fraction)
        end
      rescue ::RangeError, ::ArgumentError, ::FloatDomainError
        ""
      end

      def boundary(text) = nan_to_nil(to_number(text))
    end

    # A month counts months from 1970-01, so its number is not milliseconds and
    # its scale is 1.
    class MonthInputType < InputType
      def to_number(text, _element = nil)
        match = /\A(\d{4,})-(\d{2})\z/.match(text.to_s.strip)
        return ::Float::NAN unless match

        year, month = match[1].to_i, match[2].to_i
        return ::Float::NAN if year < 1 || month < 1 || month > 12

        ((year - 1970) * 12 + (month - 1)).to_f
      end

      def from_number(number, _element)
        return "" if number.nan?

        months = number.to_i
        year = 1970 + months.fdiv(12).floor
        format("%04d-%02d", year, (months % 12) + 1)
      end

      def boundary(text) = nan_to_nil(to_number(text))
    end

    class WeekInputType < InputType
      def scale_factor = 604_800_000

      # The epoch falls mid-week, so a week control aligns to the Monday of
      # 1970-W01; measuring from 0 would report every whole week as a step
      # mismatch.
      def step_base = to_number("1970-W01")

      def to_number(text, _element = nil)
        match = /\A(\d{4,})-W(\d{2})\z/.match(text.to_s.strip)
        return ::Float::NAN unless match

        year, week = match[1].to_i, match[2].to_i
        return ::Float::NAN if year < 1 || week < 1

        # Date.commercial raises for a week beyond the ISO year's 52/53 weeks.
        date = ::Date.commercial(year, week, 1)
        ::Time.utc(date.year, date.month, date.day).to_i * 1000.0
      rescue ::ArgumentError
        ::Float::NAN
      end

      def from_number(number, _element)
        return "" if number.nan?

        time = utc_time_from_ms(number)
        date = ::Date.new(time.year, time.month, time.day)
        format("%04d-W%02d", date.cwyear, date.cweek)
      rescue ::RangeError, ::ArgumentError, ::FloatDomainError
        ""
      end

      def boundary(text) = nan_to_nil(to_number(text))
    end

    class InputType
      NON_NUMERIC = NonNumericInputType.new.freeze

      REGISTRY = {
        "number" => NumberInputType.new.freeze,
        "range" => RangeInputType.new.freeze,
        "date" => DateInputType.new.freeze,
        "time" => TimeInputType.new.freeze,
        "datetime-local" => DatetimeLocalInputType.new.freeze,
        "month" => MonthInputType.new.freeze,
        "week" => WeekInputType.new.freeze
      }.freeze

      # The types valueAsNumber and stepUp/stepDown apply to.
      NUMERIC_NAMES = REGISTRY.keys.freeze
    end
  end
end
