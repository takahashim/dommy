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
    # Only the numeric and Date surface lives here. Value sanitization stays on
    # the element, where it reads other attributes (`multiple` for email).
    class InputType
      # The type `name` stands for. An unknown or non-numeric type answers the
      # one that has no numbers, so callers never branch on nil. REGISTRY and
      # NON_NUMERIC are at the foot of this file: they hold instances, so they
      # cannot be written until the classes below exist.
      def self.for(name) = REGISTRY.fetch(name.to_s, NON_NUMERIC)

      # Whether valueAsNumber / stepUp / stepDown apply at all.
      def numeric? = true

      # Whether valueAsDate applies: date, month, week and time only. A
      # datetime-local value names no instant (it has no time zone).
      def date? = false

      # How many of the number's units one step is worth.
      def scale_factor = 1

      # The step a control uses when it declares none.
      def default_step = 1.0

      # Where steps are measured from when `min` gives no base.
      def step_base = 0.0

      # The value string as a number, or NaN when it is not one. A pure parse:
      # nothing else about the element is consulted.
      def to_number(_text) = ::Float::NAN

      # What `valueAsNumber` reads. The same parse for every type but `range`,
      # which has no unparseable value — it answers the midpoint of its own min
      # and max instead. Separate from #to_number because value sanitization
      # wants the parse and not the substitute; they were one method with an
      # optional `element`, so which answer you got depended on remembering to
      # pass it.
      def value_of(text, _element) = to_number(text)

      # A number as the value string it writes. Never reached for a type that
      # is not numeric: the element refuses before it gets here, because it is
      # the one that knows which type to name in the error.
      def from_number(_number) = raise(NotImplementedError)

      # The value string as a Date's time value (ms since the epoch), or NaN
      # when it is not one. The number valueAsNumber reads, for every date type
      # but month, which counts months.
      def to_date_value(text) = to_number(text)

      # A Date's time value as the value string.
      def from_date_value(time_value) = from_number(time_value)

      # A `min`/`max` attribute as a number, or nil when it is not one. The
      # non-numeric type parses nothing, so this is nil for it too.
      def boundary(text) = nan_to_nil(to_number(text))

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

      # Float(string), raising ArgumentError for what is no number. A number
      # past a double's range comes out as ±Infinity, which every caller
      # already reads as no valid number; Ruby warns about it in verbose mode,
      # so the warning is held off for the conversion.
      def self.float(string)
        verbose = $VERBOSE
        $VERBOSE = nil
        Float(string)
      ensure
        $VERBOSE = verbose
      end

      def to_number(text)
        string = text.to_s
        VALID_FLOAT.match?(string) ? NumberInputType.float(string) : ::Float::NAN
      end

      def from_number(number)
        return "" if number.nan?

        number == number.to_i ? number.to_i.to_s : number.to_s
      end

      def boundary(text) = (NumberInputType.float(text) rescue nil)
    end

    # A range always reads as a number: an unparseable value is the midpoint of
    # its own min and max, which default to 0 and 100.
    class RangeInputType < NumberInputType

      def value_of(text, element)
        number = to_number(text)
        low = finite_attribute(element, "min") || 0.0
        high = finite_attribute(element, "max") || 100.0
        number = high < low ? low : low / 2.0 + high / 2.0 unless number.finite?
        number = [number, low].max
        number = [number, high].min if high >= low
        return number if element.__internal_attribute_value__("step") == "any"

        step = finite_attribute(element, "step")
        step = default_step unless step&.positive?
        base = finite_attribute(element, "min") || finite_attribute(element, "value") || step_base
        # Round in decimal arithmetic so a valid 0.6 at step 0.1 does not
        # become 0.6000000000000001, and tiny steps cannot overflow the ratio.
        number = number.to_s.to_r
        base = base.to_s.to_r
        step = step.to_s.to_r
        offset = (number - base) / step
        candidates = [offset.floor, offset.ceil].map { |n| base + n * step }
          .select { |n| n >= low && (high < low || n <= high) }
        (candidates.min_by { |n| [(n - number).abs, -n] } || number).to_f
      end

      private

      def finite_attribute(element, name)
        number = to_number(element.__internal_attribute_value__(name).to_s)
        number if number.finite?
      end
    end

    class DateInputType < InputType

      def scale_factor = 86_400_000
      def date? = true

      def to_number(text)
        match = /\A(\d{4,})-(\d{2})-(\d{2})\z/.match(text.to_s)
        return ::Float::NAN unless match

        year, month, day = match[1].to_i, match[2].to_i, match[3].to_i
        return ::Float::NAN if year < 1 || !::Date.valid_date?(year, month, day, ::Date::GREGORIAN)

        ::Time.utc(year, month, day).to_i * 1000.0
      end

      def from_number(number)
        return "" if number.nan?

        time = utc_time_from_ms(number)
        format("%04d-%02d-%02d", time.year, time.month, time.day)
      rescue ::RangeError, ::ArgumentError, ::FloatDomainError
        ""
      end

    end

    # A time is the time of day; as a Date it falls on 1970-01-01 UTC.
    class TimeInputType < InputType

      def scale_factor = 1000
      def date? = true
      def default_step = 60.0

      def to_number(text)
        match = /\A(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?\z/.match(text.to_s)
        return ::Float::NAN unless match

        hour, minute, second = match[1].to_i, match[2].to_i, match[3].to_i
        return ::Float::NAN if hour > 23 || minute > 59 || second > 59

        fraction = match[4] ? match[4].ljust(3, "0").to_i : 0
        ((hour * 3600 + minute * 60 + second) * 1000 + fraction).to_f
      end

      def from_number(number)
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

    end

    class DatetimeLocalInputType < InputType

      def scale_factor = 1000
      def default_step = 60.0

      def to_number(text)
        # The date/time separator may be "T" or a space (the "parse a local date
        # and time string" algorithm accepts both).
        match = /\A(\d{4,})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?\z/
          .match(text.to_s)
        return ::Float::NAN unless match

        year, month, day = match[1].to_i, match[2].to_i, match[3].to_i
        hour, minute, second = match[4].to_i, match[5].to_i, match[6].to_i
        return ::Float::NAN if year < 1 || !::Date.valid_date?(year, month, day, ::Date::GREGORIAN)
        return ::Float::NAN if hour > 23 || minute > 59 || second > 59

        fraction = match[7] ? match[7].ljust(3, "0").to_i : 0
        (::Time.utc(year, month, day, hour, minute, second).to_i * 1000 + fraction).to_f
      end

      def from_number(number)
        return "" unless number.finite? && number.abs <= Bridge::Date::MAX_TIME_VALUE

        time = utc_time_from_ms(number)
        return "" if time.year < 1

        base = format("%04d-%02d-%02dT%02d:%02d", time.year, time.month, time.day, time.hour, time.min)
        fraction = (number % 1000).to_i
        if time.sec.zero? && fraction.zero?
          base
        elsif fraction.zero?
          base + format(":%02d", time.sec)
        else
          base + format(":%02d.%03d", time.sec, fraction).sub(/0+\z/, "")
        end
      rescue ::RangeError, ::ArgumentError, ::FloatDomainError
        ""
      end

    end

    # A month counts months from 1970-01, so its number is not milliseconds and
    # its scale is 1.
    class MonthInputType < InputType

      def date? = true

      def to_number(text)
        match = /\A(\d{4,})-(\d{2})\z/.match(text.to_s)
        return ::Float::NAN unless match

        year, month = match[1].to_i, match[2].to_i
        return ::Float::NAN if year < 1 || month < 1 || month > 12

        ((year - 1970) * 12 + (month - 1)).to_f
      end

      def from_number(number)
        return "" if number.nan?

        months = number.to_i
        year = 1970 + months.fdiv(12).floor
        format("%04d-%02d", year, (months % 12) + 1)
      end

      # As a Date, a month is the UTC midnight that starts it.
      def to_date_value(text)
        months = to_number(text)
        return months if months.nan?

        months = months.to_i
        ::Time.utc(1970 + months.fdiv(12).floor, (months % 12) + 1).to_i * 1000.0
      end

      def from_date_value(time_value)
        return "" unless time_value.finite?

        time = utc_time_from_ms(time_value)
        format("%04d-%02d", time.year, time.month)
      rescue ::RangeError, ::ArgumentError, ::FloatDomainError
        ""
      end

    end

    # As a Date, a week is the UTC midnight of its Monday.
    class WeekInputType < InputType

      def scale_factor = 604_800_000
      def date? = true

      # The epoch falls mid-week, so a week control aligns to the Monday of
      # 1970-W01; measuring from 0 would report every whole week as a step
      # mismatch.
      def step_base = to_number("1970-W01")

      def to_number(text)
        match = /\A(\d{4,})-W(\d{2})\z/.match(text.to_s)
        return ::Float::NAN unless match

        year, week = match[1].to_i, match[2].to_i
        return ::Float::NAN if year < 1 || week < 1

        # Date.commercial raises for a week beyond the ISO year's 52/53 weeks.
        date = ::Date.commercial(year, week, 1, ::Date::GREGORIAN)
        ::Time.utc(date.year, date.month, date.day).to_i * 1000.0
      rescue ::ArgumentError
        ::Float::NAN
      end

      def from_number(number)
        return "" if number.nan?

        time = utc_time_from_ms(number)
        date = ::Date.new(time.year, time.month, time.day)
        format("%04d-W%02d", date.cwyear, date.cweek)
      rescue ::RangeError, ::ArgumentError, ::FloatDomainError
        ""
      end

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
    end
  end
end
