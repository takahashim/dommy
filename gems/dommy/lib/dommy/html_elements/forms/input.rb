# frozen_string_literal: true

module Dommy
  # The `<input>` element, whose `type` decides most of what it is. The
  # per-type arithmetic behind valueAsNumber and stepUp is Internal::InputType.
  #
  # One of the form-control groups; html_elements/forms.rb lists them.
  # `<input>` — covers the most-used form control surface.
  class HTMLInputElement < HTMLElement
    include Internal::TextSelection
    include SubmitButtonActivation
    include SubmissionUrlAttribute
    reflect_setter form_action: "formaction"
    def form_action = submission_url("formaction")
    reflect_string :name, :placeholder, :min, :max, :step, :pattern, :autocomplete, default_value: "value",
                   form_target: "formtarget"
    reflect_enumerated form_enctype: Internal::EnumeratedKeywordSets::SUBMIT_BUTTON_ENCTYPE.merge(attr: "formenctype"),
                       form_method: Internal::EnumeratedKeywordSets::SUBMIT_BUTTON_METHOD.merge(attr: "formmethod")
    reflect_boolean :autofocus, :disabled, :required, :multiple, read_only: "readonly", default_checked: "checked",
                    form_no_validate: "formnovalidate"
    # Every state the "type" attribute has (forms.spec §4.10.5.1): missing and
    # invalid value default are both the Text state.
    TYPE_KEYWORDS = %w[
      hidden text search tel url email password date month week time
      datetime-local number range color checkbox radio file submit image
      reset button
    ].freeze
    reflect_enumerated type: { keywords: TYPE_KEYWORDS, missing: "text", invalid: "text" }
    # Own __js_call__ methods, on top of Element's.

    def __submit_button__? = %w[submit image].include?(type) && !disabled

    # Runtime value/checked. Dommy has no UI, so the runtime state is
    # initialized from the attribute on first access and tracked
    # separately thereafter — matching browser semantics where the
    # `value` IDL attribute can drift from the `value` content attr.
    def value
      raw = @__value.nil? ? reflected_string("value") : @__value
      # checkbox/radio use the "default/on" value mode: with no value content
      # attribute (and no assigned value) the IDL value is "on".
      return "on" if raw.to_s.empty? && !@__node__.key?("value") && CHECKABLE_TYPES.include?(type)

      sanitize_value(raw)
    end

    def value=(v)
      raw = v.to_s
      # WHATWG: a file input's value IDL setter throws unless set to the empty
      # string (which clears the selection).
      if type == "file" && !raw.empty?
        raise DOMException::InvalidStateError, "a file input's value may only be set to the empty string"
      end
      @__raw_value = raw
      @__value = raw
      # The IDL value is selector-observable (:invalid / :in-range /
      # :placeholder-shown) with no attribute mutation behind it.
      @document&.__internal_note_value_change__
    end

    # `files` — for `<input type="file">`. Browsers populate this via
    # user interaction; in tests, code uses `__driver_set_files__` to seed it.
    def files
      # `files` is null for every type other than file (WHATWG).
      return nil unless type == "file"

      @__files ||= FileList.new
    end

    # Test-only seam: set the input's file list directly.
    # Accepts an array (wrapped in a FileList) or a FileList itself.
    def __driver_set_files__(files_input)
      @__files = files_input.is_a?(FileList) ? files_input : FileList.new(Array(files_input))
    end

    # maxLength / minLength reflect a "limited to only non-negative numbers"
    # long: a missing / negative / non-numeric content attribute reads as -1.
    def max_length = parse_non_negative_reflected("maxlength")
    def min_length = parse_non_negative_reflected("minlength")

    def max_length=(value)
      set_non_negative_reflected("maxlength", value)
    end

    def min_length=(value)
      set_non_negative_reflected("minlength", value)
    end

    # Spec: the "value sanitization algorithm" runs lazily on read.
    # type=email/url trim leading/trailing ASCII whitespace; type=number
    # rejects non-finite floats by returning "" (badInput stays true
    # so validity surfaces the original raw value).
    # The strategy for this control's `type`: what a number means here, and what
    # a step is worth. The sixteen `case type` branches that used to answer
    # these live in Internal::InputType, one class per type.
    def input_type = Internal::InputType.for(type)

    def value_as_number = input_type.value_of(value.to_s, self)

    def value_as_number=(number)
      unless input_type.numeric?
        raise DOMException::InvalidStateError, "valueAsNumber is not applicable to input type '#{type}'"
      end

      self.value = input_type.from_number(number.to_f)
    end

    def validation_step_base = min_as_number || input_type.step_base

    def numeric_value_type? = input_type.numeric?

    def step_scale_factor = input_type.scale_factor

    def default_step = input_type.default_step

    def step_boundary(attr)
      raw = @__node__[attr].to_s.strip
      return nil if raw.empty?

      input_type.boundary(raw)
    end

    def sanitize_value(raw)
      case type
      # The one-line text types "strip newlines from the value" (WHATWG value
      # sanitization) — a pasted multi-line string collapses to one line.
      when "text", "search", "tel", "password"
        strip_newlines(raw.to_s)
      when "email"
        stripped = strip_newlines(raw.to_s)
        if @__node__.key?("multiple")
          stripped.split(",").map(&:strip).join(",")
        else
          stripped.strip
        end
      when "url"
        # Strip newlines, then leading/trailing whitespace.
        strip_newlines(raw.to_s).strip
      when "number", "range"
        sanitize_number(raw)
      when "color"
        s = raw.to_s.strip.downcase
        s.match?(/\A#[0-9a-f]{6}\z/) ? s : "#000000"
      else
        raw.to_s
      end
    end

    def strip_newlines(str)
      str.gsub(/[\r\n]/, "")
    end

    # HTML's value sanitization for number and range: anything that is not a
    # valid floating-point number, or is out of the finite range, is the
    # empty string. Ruby's Float() is wider than the spec (" 1", "+1", "1.").
    def sanitize_number(raw)
      s = raw.to_s
      input_type.to_number(s).finite? ? s : ""
    end

    # Underlying string the user supplied to `value=`, before any
    # sanitization. Used by ValidityState.badInput so a non-parseable
    # number still trips constraint validation.
    def raw_value
      @__raw_value || @__value || reflected_string("value")
    end

    def checked
      @__checked.nil? ? default_checked : @__checked
    end

    def checked=(v)
      @__checked = !!v
      # A radio becoming checked unchecks the rest of its radio button group.
      uncheck_radio_group if @__checked && type == "radio"
      # Checkedness is property state (no attribute mutation fires), yet it
      # is selector-observable via :checked — invalidate cached query results
      # and computed styles.
      @document&.__internal_note_selector_state_change__
    end

    # `indeterminate` is pure property state (no content attribute), default
    # false. Selector-observable via :indeterminate, so bump style generation.
    def indeterminate
      @__indeterminate || false
    end

    def indeterminate=(v)
      @__indeterminate = !!v
      @document&.__internal_note_selector_state_change__
    end

    # --- Click activation behavior (checkbox / radio) -------------------

    # A checkbox / radio / reset button has activation behavior of its own, on
    # top of the submit-button behavior HTMLInputElement inherits. Checkbox and
    # radio are the two states HTML's input activation behavior runs for even
    # when the control is not mutable — `click()` still refuses on a disabled
    # control, but an explicitly dispatched click activates it.
    def activation_target?
      super || CHECKABLE_TYPES.include?(type) || (type == "reset" && !disabled)
    end

    # HTML "input activation behavior": a submit button submits its form, a reset
    # button resets it, and a checkbox / radio fires `input` then `change` — but
    # only when connected, so clicking a detached checkbox toggles it silently.
    # Both events are UA-generated, so trusted.
    def activation_behavior(event)
      return super if __submit_button__?
      return form&.reset if type == "reset" && !disabled
      return unless CHECKABLE_TYPES.include?(type) && is_connected?

      dispatch_event(Event.new("input", "bubbles" => true).__internal_mark_trusted__)
      dispatch_event(Event.new("change", "bubbles" => true).__internal_mark_trusted__)
    end

    # HTML reset algorithm: drop the dirty value and dirty checkedness flags, so
    # `value` / `checked` fall back to the `value` / `checked` content attributes.
    def __internal_reset__
      @__value = nil
      @__raw_value = nil
      @__checked = nil
      @__indeterminate = nil
      # Value AND checkedness reverted: both are selector-observable, neither
      # mutates an attribute.
      @document&.__internal_note_value_change__
      @document&.__internal_note_selector_state_change__
      nil
    end

    # HTML legacy-pre-activation behavior: a checkbox toggles; a radio becomes
    # checked (which unchecks its group). Runs before the click is dispatched, so
    # a listener already sees the new state. Returns the state needed to undo it
    # if the click is canceled, or nil for inputs with no such behavior.
    def legacy_pre_activation_behavior
      case type
      when "checkbox"
        old = checked
        old_indeterminate = indeterminate
        # Pre-click activation clears indeterminate, then toggles checkedness.
        self.indeterminate = false
        self.checked = !old
        { kind: :checkbox, old_checked: old, old_indeterminate: old_indeterminate }
      when "radio"
        old_checked = checked
        previously_checked = old_checked ? nil : currently_checked_in_radio_group
        self.checked = true
        { kind: :radio, old_checked: old_checked, previously_checked: previously_checked }
      end
    end

    # Canceled (default prevented): restore the pre-click checkedness. For a
    # radio, also re-check whichever member was checked before.
    def legacy_canceled_activation_behavior(state)
      case state[:kind]
      when :checkbox
        self.checked = state[:old_checked]
        self.indeterminate = state[:old_indeterminate]
      when :radio
        self.checked = state[:old_checked]
        prev = state[:previously_checked]
        prev.checked = true if prev && !prev.equal?(self)
      end
    end

    # The currently-checked radio in this element's group (or nil).
    def currently_checked_in_radio_group
      radio_group_members.find { |radio| radio.checked && !radio.equal?(self) }
    end

    # Uncheck every other radio in this element's group.
    def uncheck_radio_group
      radio_group_members.each do |radio|
        next if radio.equal?(self)

        radio.__internal_set_checked_silently__(false)
      end
    end

    # Set checkedness without re-running the group cascade (used while
    # unchecking peers).
    def __internal_set_checked_silently__(value)
      @__checked = !!value
      @document&.__internal_note_selector_state_change__
    end

    # Two controls share a form owner when both are formless, or both point at
    # the same form element (compared by backend node identity).
    def same_form_owner?(a, b)
      return b.nil? if a.nil?
      return false if b.nil?

      a.__dommy_backend_node__.equal?(b.__dommy_backend_node__)
    end

    # The radio button group: radios in the SAME tree (root node — so an orphan
    # subtree groups too) that share this element's non-empty name and form
    # owner (two radios with no form owner still group, as long as they share a
    # tree and name).
    def radio_group_members
      group_name = get_attribute("name").to_s
      return [self] if group_name.empty?

      owner = form_owner
      root = get_root_node
      return [self] unless root.respond_to?(:query_selector_all)

      members = root.query_selector_all("input[type='radio']").to_a.select do |radio|
        next false unless radio.respond_to?(:form_owner)
        next false unless radio.get_attribute("name").to_s == group_name

        same_form_owner?(owner, radio.form_owner)
      end
      # `query_selector_all` searches descendants, so a detached radio (whose
      # root node is itself) isn't returned — a radio is always in its own group.
      members.any? { |m| m.__dommy_backend_node__.equal?(__dommy_backend_node__) } ? members : members + [self]
    end

    def labels
      # A hidden input is not a labelable element, so it has no labels list.
      return nil if type == "hidden"

      labels_node_list
    end

    # The form owner (WebIDL `input.form`): the form referenced by a `form=`
    # content attribute (when it resolves to a form element), otherwise the
    # nearest ancestor form.
    def form
      form_owner
    end

    def form_owner
      __internal_form_owner__
    end

    # Only these input types expose a variable-length text selection; the rest
    # return null for the selection attributes and throw on the setters/methods.
    # The types whose checkedness is the value the user toggles, rather than
    # text they type. Three separate `%w[checkbox radio]` literals asked this.
    CHECKABLE_TYPES = %w[checkbox radio].freeze

    # The JS surface: the computed properties, declared instead of written out
    # as `when "validity" then validity` arms. Internal::ReflectedAttributes'
    # shared __js_get__ / __js_set__ answer from this.
    js_accessor :value, :checked, :indeterminate,
      value_as_number: "valueAsNumber",
      selection_start: "selectionStart", selection_end: "selectionEnd",
      selection_direction: "selectionDirection",
      max_length: "maxLength", min_length: "minLength"
    js_readable :labels, :form, :validity, :files, :list,
      will_validate: "willValidate", validation_message: "validationMessage"

    SELECTION_TYPES = %w[text search url tel password].freeze

    # Only the one-line text types carry a selection; a checkbox or a number
    # spinner has none, and its setters raise (HTML "set the selection range").
    def supports_selection? = SELECTION_TYPES.include?(type)

    private def require_selection!
      return if supports_selection?

      raise DOMException::InvalidStateError,
        "The input element's type ('#{type}') does not support selection."
    end
    public







    # `select()` selects the whole control on a text control; on any other type
    # it is a silent no-op (it does NOT throw).
    def select
      return nil unless supports_selection?

      @__selection_start = 0
      @__selection_end = value.to_s.length
      @__selection_direction = "none"
      nil
    end










    # The declared step (default 1 for number, 1 for range); "any" disables
    # stepping (returns nil).
    def step_base_value
      raw = @__node__["step"].to_s.strip
      return nil if raw.casecmp?("any")

      s = (Float(raw) rescue nil)
      s && s > 0 ? s : default_step
    end

    # stepUp/stepDown throw when the type has no allowed value step: a type with
    # no number representation, or step="any". Otherwise the value moves by
    # `count` steps (in valueAsNumber units), clamped/aligned to the min & max.
    def apply_step(count)
      unless numeric_value_type?
        raise DOMException::InvalidStateError, "stepUp/stepDown is not applicable to input type '#{type}'"
      end

      step = step_base_value
      if step.nil?
        raise DOMException::InvalidStateError, "stepUp/stepDown is not allowed when step is 'any'"
      end
      return if count.zero?

      allowed = step * step_scale_factor
      mn = step_boundary("min")
      mx = step_boundary("max")
      # A min above the max means no in-range value exists — do nothing.
      return if mn && mx && mn > mx

      before = value_as_number
      # The arithmetic runs on the decimal values the attributes spell, not on
      # their nearest doubles: 0.1 + 0.1 + 0.1 is 0.3, not 0.30000000000000004.
      allowed = decimal(allowed)
      mn = decimal(mn) if mn
      mx = decimal(mx) if mx
      base = before.nan? ? (mn || 0r) : decimal(before)
      result = base + count * allowed

      step_base = mn || 0r
      result = mx - (mx - step_base) % allowed if mx && result > mx
      result = mn + (step_base - mn) % allowed if mn && result < mn

      # Clamping must never move the value against the step direction (e.g. a
      # stepDown on a value already below min must not jump UP to min).
      unless before.nan?
        return if count.positive? && result < before
        return if count.negative? && result > before
      end

      self.value_as_number = result.to_f
      nil
    end

    # The decimal number a double stands for: 0.1 is 1/10, not the binary
    # fraction nearest to it.
    def decimal(number)
      number.rationalize(Rational(1, 10**12))
    end






    # WHATWG "valid floating-point number": no surrounding whitespace (unlike
    # Ruby's Float()), optional sign, digits with optional fraction, optional
    # exponent. Anything else — including " 1 " or "1e" — yields NaN.
    # A fraction needs a digit after the dot, so "1." is not a number.


    # --- Date/time "convert a string to a number" algorithms (all UTC) --------






    # --- Inverse: "convert a number to a string" for the date/time types -------









    # Numeric-domain accessors shared with constraint validation (rangeUnderflow
    # / rangeOverflow / stepMismatch), all in valueAsNumber units.
    def min_as_number
      step_boundary("min")
    end

    def max_as_number
      step_boundary("max")
    end

    # The allowed value step in valueAsNumber units, or nil for step="any" / a
    # type with no stepping.
    def allowed_value_step
      return nil unless numeric_value_type?

      step = step_base_value
      step.nil? ? nil : step * step_scale_factor
    end


    # `stepUp(n)` / `stepDown(n)` add/subtract n steps to the current number. The
    # WebIDL default for n is 1 (a missing/undefined arg crosses as nil).
    def step_up(n = 1)
      apply_step((n || 1).to_i)
    end

    def step_down(n = 1)
      apply_step(-(n || 1).to_i)
    end

    def validity
      @__validity ||= ValidityState.new(self)
    end

    # Whether this control participates in constraint validation. Only the
    # Hidden, Reset Button and Button states are barred outright — a submit or
    # image button is a submittable element like any other, and validates (it
    # just has no constraints of its own beyond a custom validity message).
    def will_validate
      return false if reflected_boolean("disabled")
      return false if disabled_by_ancestor_fieldset?
      return false if reflected_boolean("readonly")
      return false if %w[hidden button reset].include?(type)
      # A control with a datalist ancestor is barred from constraint validation.
      return false unless closest("datalist").nil?

      true
    end

    def validation_message
      return "" unless will_validate

      msg = (@custom_validity_message || "").to_s
      return msg unless msg.empty?
      return "Please fill out this field." if validity.value_missing
      return "Please match the requested format." if validity.pattern_mismatch
      return "Please enter a valid email address." if validity.type_mismatch && type == "email"
      return "Please enter a URL." if validity.type_mismatch && type == "url"

      ""
    end

    def check_validity
      ok = !will_validate || validity.valid
      dispatch_event(Event.new("invalid", "bubbles" => false, "cancelable" => true)) unless ok
      ok
    end

    def report_validity
      check_validity
    end

    def set_custom_validity(msg)
      @custom_validity_message = msg.to_s
      nil
    end


    # HTML "cloning steps" for input: the dirty value flag + value and the dirty
    # checkedness flag + checkedness (plus indeterminate) — the user-modified
    # state a clone must retain beyond the default* content attributes. Returns
    # nil when the control is still pristine, so the walk skips it.
    def __cloning_state__
      state = {}
      state[:value] = @__value unless @__value.nil?
      state[:raw_value] = @__raw_value unless @__raw_value.nil?
      state[:checked] = @__checked unless @__checked.nil?
      state[:indeterminate] = @__indeterminate unless @__indeterminate.nil?
      state.empty? ? nil : state
    end

    def __apply_cloning_state__(state)
      @__value = state[:value] if state.key?(:value)
      @__raw_value = state[:raw_value] if state.key?(:raw_value)
      @__checked = state[:checked] if state.key?(:checked)
      @__indeterminate = state[:indeterminate] if state.key?(:indeterminate)
    end

    # HTMLInputElement.list — the <datalist> referenced by the `list` content
    # attribute (resolved by id, first element in tree order). Null when there
    # is no `list` attribute, no element with that id, or the referenced element
    # is not a <datalist>.
    def list
      id = get_attribute("list")
      return nil if id.nil? || id.empty?

      element = @document.get_element_by_id(id)
      element.is_a?(HTMLDataListElement) ? element : nil
    end


    js_methods %w[
      select setSelectionRange setRangeText stepUp stepDown checkValidity reportValidity
      setCustomValidity
    ]
    def __js_call__(method, args)
      case method
      when "select"
        select
      when "setSelectionRange"
        set_selection_range(args[0], args[1], args[2])
      when "setRangeText"
        set_range_text(args[0])
      when "stepUp"
        step_up(args[0])
      when "stepDown"
        step_down(args[0])
      when "checkValidity"
        check_validity
      when "reportValidity"
        report_validity
      when "setCustomValidity"
        set_custom_validity(args[0])
      else
        super
      end
    end
  end

  # `<button>` — type defaults to "submit" per spec.

  # `<button>` — type defaults to "submit" per spec.
end
