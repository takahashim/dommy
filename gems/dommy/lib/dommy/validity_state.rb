# frozen_string_literal: true

module Dommy
  # `ValidityState` — computes constraint-validation flags from the
  # host control's current attributes and value. Bound to a single
  # host control; reads dynamically on every access so attribute
  # changes between calls are reflected.
  #
  # Flags follow the HTML spec, each constraint only where its attribute
  # applies. A host-less ValidityState (an element barred outright) has none.
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

    # The input types each attribute applies to (HTML's "do not apply" table).
    TEXTUAL_TYPES = %w[text search url tel email password].freeze
    REQUIRED_TYPES = (TEXTUAL_TYPES + %w[date month week time datetime-local number checkbox radio file]).freeze
    READONLY_TYPES = (TEXTUAL_TYPES + %w[date month week time datetime-local number]).freeze
    # The types whose value sanitization drops what it cannot parse, so that a
    # user's unparseable input is "bad input".
    PARSED_TYPES = %w[number date month week time datetime-local].freeze

    def initialize(host = nil)
      @host = host
    end

    # ---- Computed flags ----

    # Whether the host is mutable: not (actually) disabled, and without a
    # `readonly` attribute where readonly applies. A text-like control only
    # "suffers from being missing" while it is mutable; the checkbox, radio,
    # file and select definitions carry no such condition.
    def host_mutable?
      return false if @host.__internal_actually_disabled__
      return true unless host_attr_present?("readonly")

      case @host
      when HTMLInputElement then !READONLY_TYPES.include?(host_type)
      when HTMLTextAreaElement then false
      else true
      end
    end

    def value_missing
      case @host
      when HTMLInputElement then input_value_missing
      when HTMLTextAreaElement then host_attr_present?("required") && host_mutable? && host_value.empty?
      when HTMLSelectElement then select_value_missing
      else false
      end
    end

    def input_value_missing
      type = host_type
      return false unless REQUIRED_TYPES.include?(type)
      # HTML: a radio suffers from being missing when ANY member of its group
      # is required and none is checked — the member asked need not be the
      # required one. A radio with no name is in no group, so never is.
      if type == "radio"
        return false if @host.__internal_attribute_value__("name").to_s.empty?

        group = @host.radio_group_members
        return group.any? { |radio| radio.__internal_has_attribute__?("required") } && group.none?(&:checked)
      end
      return false unless host_attr_present?("required")

      case type
      when "checkbox" then !@host.checked
      when "file" then @host.files.nil? || @host.files.length.zero?
      else host_mutable? && host_value.empty?
      end
    end

    # A required select is missing when nothing in its list of options is
    # selected, or the one selected option is its placeholder label option.
    def select_value_missing
      return false unless host_attr_present?("required")

      options = @host.__internal_list_of_options__
      selected = options.select(&:selected)
      return true if selected.empty?

      placeholder = placeholder_label_option(options)
      selected.length == 1 && !placeholder.nil? && selected.first.equal?(placeholder)
    end

    # HTML's "placeholder label option": for a required, single, display-size
    # 1 select, the first option in its list of options when its value is
    # empty and it is the select's own child (not in an optgroup).
    def placeholder_label_option(options)
      return nil if @host.multiple || @host.display_size != 1

      first = options.first
      return nil if first.nil? || !first.value.to_s.empty?

      parent = first.parent_node
      parent.equal?(@host) ? first : nil
    end

    def type_mismatch
      return false unless @host.is_a?(HTMLInputElement)

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
        # "A valid absolute URL": one the URL parser accepts without a base.
        Internal::UrlParser.parse(v).nil?
      else
        false
      end
    rescue StandardError
      true
    end

    def pattern_mismatch
      return false unless @host.is_a?(HTMLInputElement) && TEXTUAL_TYPES.include?(host_type)

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
    # EDIT (not a script assignment) and the dirty value flag is set, per the
    # WHATWG "suffering from being too long/short" definitions — so only a
    # driver's typing (Dommy::Interaction) can trip them. Lengths are the API
    # value's UTF-16 code units.
    def too_long
      limit = length_limit(:max_length)
      !limit.nil? && Internal::Utf16.length(host_value) > limit
    end

    def too_short
      limit = length_limit(:min_length)
      return false if limit.nil?

      length = Internal::Utf16.length(host_value)
      length.positive? && length < limit
    end

    def length_limit(attribute)
      applies = @host.is_a?(HTMLTextAreaElement) ||
                (@host.is_a?(HTMLInputElement) && TEXTUAL_TYPES.include?(host_type))
      return nil unless applies && @host.__internal_last_changed_by_user_edit__

      limit = @host.public_send(attribute)
      limit.negative? ? nil : limit
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

    # `badInput`: the user typed something the user agent could not convert —
    # a driver's `fill_in "abc"` on a number field, whose sanitization then
    # left the value empty. A script-assigned value is sanitized, never bad.
    def bad_input
      return false unless @host.is_a?(HTMLInputElement) && PARSED_TYPES.include?(host_type)

      raw = @host.__internal_user_raw_value__
      !raw.nil? && !raw.empty? && host_value.empty?
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
      return "" unless @host.respond_to?(:value)

      @host.value.to_s
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
      return "" unless @host.respond_to?(:__internal_custom_validity_message__)

      @host.__internal_custom_validity_message__
    end

    def numeric_host?
      @host.is_a?(HTMLInputElement) && @host.respond_to?(:numeric_value_type?) &&
        @host.send(:numeric_value_type?)
    end

  end

  # `<option>` — value, label, selected, disabled, text, index, form.
end
