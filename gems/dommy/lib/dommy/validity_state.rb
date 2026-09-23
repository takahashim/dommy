# frozen_string_literal: true

module Dommy
  # `ValidityState` — computes constraint-validation flags from the
  # host control's current attributes and value. Bound to a single
  # host control; reads dynamically on every access so attribute
  # changes between calls are reflected.
  #
  # Flags follow the HTML spec; `badInput` is always false (we'd need
  # the browser's number parser to detect "12abc" in a type=number).
  class ValidityState
    FLAGS = %w[
      valueMissing
      typeMismatch
      patternMismatch
      tooLong
      tooShort
      rangeUnderflow
      rangeOverflow
      stepMismatch
      badInput
      customError
    ]
      .freeze

    # The exact WHATWG "valid email address" production.
    EMAIL_RE = %r{\A[a-zA-Z0-9.!\#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\z}
    URL_SCHEMES = %w[http:// https:// ftp://].freeze

    def initialize(host = nil)
      @host = host
    end

    # ---- Computed flags ----

    # Whether the host is IMMUTABLE — disabled or readonly. A text-like control
    # "suffers from being missing" only while it is mutable, which is why this
    # gates value_missing (and only value_missing: the checkbox / radio / select
    # definitions carry no mutability condition, so they report the flag even
    # when barred).
    #
    # "Disabled" here is WHATWG's "actually disabled", so a control inside a
    # `<fieldset disabled>` counts even though it carries no attribute of its
    # own — the same state willValidate already reports on.
    def host_immutable?
      return false unless @host

      disabled =
        if @host.respond_to?(:__internal_actually_disabled__)
          @host.__internal_actually_disabled__
        else
          host_attr_present?("disabled")
        end
      readonly = @host.respond_to?(:readonly) ? @host.readonly : host_attr_present?("readonly")
      disabled || readonly
    end

    def value_missing
      return false unless @host && host_attr_present?("required")

      case host_type
      when "checkbox"
        # The checkbox/radio "being missing" flag reflects checkedness even when
        # the control is barred (only willValidate gates participation).
        !host_checked?
      when "radio"
        # An unnamed radio is not part of a group and is never missing.
        return false if @host.respond_to?(:get_attribute) && @host.get_attribute("name").to_s.empty?

        # A required radio is missing only when NO member of its group (same
        # name/form owner/tree) is checked — using runtime checkedness.
        if @host.respond_to?(:radio_group_members)
          @host.radio_group_members.none? { |r| r.respond_to?(:checked) ? r.checked : false }
        else
          !host_checked?
        end
      when "file"
        files = @host.respond_to?(:files) ? @host.files : nil
        files.nil? || files.length.zero?
      when "select-one", "select-multiple"
        # A required select is missing when its selected option has an empty
        # value (the placeholder label option); the flag isn't barred by disabled.
        @host.respond_to?(:value) && @host.value.to_s.empty?
      else
        # Text-like controls only "suffer from being missing" when mutable.
        return false if host_immutable?

        # A date/number type with an unparseable value has no value (its
        # sanitized value is empty), so it counts as missing.
        if @host.respond_to?(:numeric_value_type?) && @host.send(:numeric_value_type?)
          @host.value_as_number.nan?
        else
          host_value.to_s.empty?
        end
      end
    end

    def type_mismatch
      return false unless @host

      v = host_value.to_s
      return false if v.empty?

      case host_type
      when "email"
        # A `multiple` email is a comma-separated list; every part must be valid.
        if host_attr_present?("multiple")
          v.split(",", -1).any? { |part| !part.strip.match?(EMAIL_RE) }
        else
          !v.match?(EMAIL_RE)
        end
      when "url"
        URL_SCHEMES.none? { |s| v.start_with?(s) }
      else
        false
      end
    end

    def pattern_mismatch
      return false unless @host

      pat = host_attr_value("pattern").to_s
      return false if pat.empty?

      v = host_value.to_s
      return false if v.empty?
      # HTML compiles the pattern as a JavaScript RegExp with the `v` flag and
      # ignores the attribute entirely if that fails.
      return false if v_mode_syntax_error?(pat)

      # The pattern must be a valid regex ON ITS OWN — validate it before
      # anchoring, so an unbalanced `a)(b` (which the `(?:…)` wrapper would
      # otherwise balance) is correctly discarded rather than silently matched.
      Regexp.new(pat)
      anchored = Regexp.new("\\A(?:#{pat})\\z")
      # A `multiple` email is a comma-separated list, and the pattern is matched
      # against each entry rather than the list as a whole.
      pattern_values(v).any? { |part| !anchored.match?(part) }
    rescue RegexpError
      false
    end

    # The values the pattern is matched against: one per comma-separated entry
    # for a `multiple` email control, otherwise the value itself.
    def pattern_values(value)
      return [value] unless host_type == "email" && host_attr_present?("multiple")

      value.split(",", -1).map(&:strip)
    end

    # Characters that carry no syntactic role inside a JavaScript `v`-mode
    # character class and so must be escaped there. `[(]` — legal in every other
    # regex dialect, Ruby's included — is a syntax error under `v`, which is why
    # HTML then ignores the pattern rather than reporting a mismatch. (`[`, `]`
    # and `-` do have roles: nested classes and ranges.)
    V_MODE_CLASS_RESERVED = "(){}/|"

    def v_mode_syntax_error?(pattern)
      depth = 0
      escaped = false
      pattern.each_char do |ch|
        if escaped
          escaped = false
          next
        end

        case ch
        when "\\" then escaped = true
        when "[" then depth += 1
        when "]" then depth -= 1 if depth.positive?
        else
          return true if depth.positive? && V_MODE_CLASS_RESERVED.include?(ch)
        end
      end
      false
    end

    # tooLong / tooShort apply ONLY when the value was last changed by a USER
    # EDIT (not a script assignment), per the WHATWG "suffering from being too
    # long/short" definitions. Dommy has no interactive text entry, so a value is
    # never user-edited and these constraints never fire.
    def too_long
      false
    end

    def too_short
      false
    end

    def range_underflow
      return false unless numeric_host?

      min = @host.min_as_number
      return false if min.nil?

      num = @host.value_as_number
      return false if num.nan?
      # A `time` control has a periodic domain: min > max means a REVERSED range
      # whose accepted values are `>= min` OR `<= max`, so both underflow and
      # overflow hold for a value in the excluded gap (max, min).
      max = @host.max_as_number
      return num > max && num < min if reversed_range?(min, max)

      num < min
    end

    def range_overflow
      return false unless numeric_host?

      max = @host.max_as_number
      return false if max.nil?

      num = @host.value_as_number
      return false if num.nan?
      min = @host.min_as_number
      return num > max && num < min if reversed_range?(min, max)

      num > max
    end

    # A reversed range only exists for the periodic `time` domain with min > max.
    def reversed_range?(min, max)
      host_type == "time" && min && max && min > max
    end

    def step_mismatch
      return false unless numeric_host?

      step = @host.allowed_value_step
      return false if step.nil?

      num = @host.value_as_number
      return false if num.nan?

      # Decimal arithmetic, not binary: `step=0.003, value=3.6` is an exact
      # multiple in base 10 but not in IEEE-754, and `step=3e-15, value=17` is
      # the reverse — the float division lands exactly on an integer. Reading
      # each number back from its shortest round-trip decimal recovers the
      # literal the author wrote (Rational("3.6") is exactly 18/5) and gets
      # both right.
      ratio = Rational((num - @host.validation_step_base).to_s) / Rational(step.to_s)
      ratio.denominator != 1
    rescue ArgumentError, FloatDomainError, ZeroDivisionError
      false
    end

    # `badInput` flags input that the user agent couldn't convert to
    # the host control's expected type. For Dommy this is meaningful
    # for type=number/range (raw string not a finite float) and
    # type=color (not a #rrggbb literal).
    def bad_input
      return false unless @host

      raw = @host.respond_to?(:raw_value) ? @host.raw_value : host_value
      raw = raw.to_s
      return false if raw.empty?

      case host_type
      when "number", "range"
        !valid_float?(raw)
      else
        # Every other type either has no conversion to fail or (color, date and
        # friends) sanitizes an unparseable value to a valid one on the way in,
        # leaving nothing for the user agent to have failed to convert.
        false
      end
    end

    def valid_float?(s)
      Float(s)
      true
    rescue ArgumentError, TypeError
      false
    end

    def custom_error
      !custom_message.empty?
    end

    def valid
      !(value_missing ||
        type_mismatch ||
        pattern_mismatch ||
        too_long ||
        too_short ||
        range_underflow ||
        range_overflow ||
        step_mismatch ||
        bad_input ||
        custom_error)
    end

    # ---- Bridge protocol ----

    def __js_get__(key)
      case key
      when "valueMissing"
        value_missing
      when "typeMismatch"
        type_mismatch
      when "patternMismatch"
        pattern_mismatch
      when "tooLong"
        too_long
      when "tooShort"
        too_short
      when "rangeUnderflow"
        range_underflow
      when "rangeOverflow"
        range_overflow
      when "stepMismatch"
        step_mismatch
      when "badInput"
        bad_input
      when "customError"
        custom_error
      when "valid"
        valid
      else
        Bridge::ABSENT
      end
    end

    private

    def host_value
      return "" unless @host

      @host.respond_to?(:value) ? @host.value : @host.__js_get__("value")
    end

    def host_attr_value(name)
      return "" unless @host

      @host.__dommy_backend_node__[name].to_s
    end

    def host_attr_present?(name)
      return false unless @host

      @host.__dommy_backend_node__.key?(name.to_s)
    end

    # Runtime checkedness of a checkbox/radio host (the `.checked` IDL state,
    # which can drift from the `checked` content attribute).
    def host_checked?
      @host.respond_to?(:checked) ? @host.checked : host_attr_present?("checked")
    end

    def host_type
      return nil unless @host

      @host.respond_to?(:type) ? @host.type : ""
    end

    def custom_message
      return "" unless @host

      (@host.instance_variable_get(:@custom_validity_message) || "").to_s
    end

    def numeric_host?
      @host.is_a?(HTMLInputElement) && @host.respond_to?(:numeric_value_type?) &&
        @host.send(:numeric_value_type?)
    end

    def numeric_value
      v = host_value.to_s
      return nil if v.empty?

      Float(v)
    rescue ArgumentError
      nil
    end

    def truthy?(value)
      v = value.to_s
      !v.empty? && v != "false" && v != "0"
    end
  end

  # `<option>` — value, label, selected, disabled, text, index, form.
end
