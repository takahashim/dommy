# frozen_string_literal: true

module Dommy
  # The `<input>` element, whose `type` decides most of what it is. The
  # per-type arithmetic behind valueAsNumber and stepUp is Internal::InputType.
  #
  # One of the form-control groups; html_elements/forms.rb lists them.
  # `<input>` — covers the most-used form control surface.
  class HTMLInputElement < HTMLElement
    include Internal::TextSelection
    include Internal::ConstraintValidation
    include SubmitButtonActivation
    include SubmissionUrlAttribute
    reflect_setter form_action: "formaction"
    def form_action = submission_url("formaction")
    # `autocomplete` — the setter reflects, but the getter is HTML's autofill
    # processing model (Internal::Autofill). An input wears the "autofill
    # anchor mantle" only when its type is Hidden, which is HTML's one case
    # where a bare "on"/"off" is invalid rather than passed through.
    reflect_setter :autocomplete
    def autocomplete
      Internal::Autofill.idl_exposed_value(__internal_attribute_value__("autocomplete"), anchor_mantle: type == "hidden")
    end
    reflect_enumerated form_enctype: Internal::EnumeratedKeywordSets::SUBMIT_BUTTON_ENCTYPE.merge(attr: "formenctype"),
                       form_method: Internal::EnumeratedKeywordSets::SUBMIT_BUTTON_METHOD.merge(attr: "formmethod")
    # `switch` (the checkbox switch control) is not in the IDL the table is
    # generated from yet; the rest of the plain reflections (name, maxLength,
    # size, …) come from the IDL and its overlay (Internal::IdlReflection).
    reflect_boolean :switch
    reflect_enumerated color_space: { attr: "colorspace", keywords: %w[limited-srgb display-p3],
                                      missing: "limited-srgb", invalid: "limited-srgb" }
    # `width` / `height` [ReflectSetter]: the getter is the dimensions of an
    # Image Button (its dimension attributes, as nothing is rendered), and 0
    # for every other type.
    reflect_ulong_setter :width, :height
    def width = type == "image" ? reflected_ulong("width") : 0
    def height = type == "image" ? reflected_ulong("height") : 0
    # Every state the "type" attribute has (forms.spec §4.10.5.1): missing and
    # invalid value default are both the Text state.
    TYPE_KEYWORDS = %w[
      hidden text search tel url email password date month week time
      datetime-local number range color checkbox radio file submit image
      reset button
    ].freeze
    TYPE_STATES = { keywords: TYPE_KEYWORDS, missing: "text", invalid: "text" }.freeze
    reflect_enumerated type: TYPE_STATES
    # Own __js_call__ methods, on top of Element's.

    def __internal_submit_button__? = %w[submit image].include?(type) && !disabled

    include Internal::PopoverInvokerElement

    # An input in the Submit Button, Image Button, Reset Button or Button
    # state is a "button", which can invoke a popover.
    def __internal_popover_invoker_button__? = %w[submit image reset button].include?(type)

    def __internal_submit_button_state__? = %w[submit image].include?(type)

    # An Image Button's "selected coordinate" — where the user clicked on the
    # image. Dommy lays nothing out, so it is always the origin.
    def __internal_selected_coordinate__ = [0, 0]

    # Value-mode controls keep a sanitized current value and a separate dirty
    # flag. Attribute writes update pristine controls; IDL writes make them
    # dirty. Default/default-on controls reflect the content attribute instead.
    def value
      case value_mode(type)
      when :default then default_value
      when :default_on then __internal_attribute_value__("value") || "on"
      when :filename then files.empty? ? "" : "C:\\fakepath\\#{files.item(0).name}"
      else current_value
      end
    end

    def value=(v)
      raw = v.to_s
      case value_mode(type)
      when :default, :default_on
        self.default_value = raw
      when :filename
        unless raw.empty?
          raise DOMException::InvalidStateError, "a file input's value may only be set to the empty string"
        end
        @__files = FileList.new
      else
        old_value = current_value
        @__user_raw_value = nil
        @__last_changed_by_user_edit = false
        @__raw_value = raw
        @__value = sanitize_value(raw)
        @__value_dirty = true
        # HTML: a value that changed moves the text entry cursor to the end.
        __internal_move_cursor_to_end__ if supports_selection? && @__value != old_value
      end
      # The IDL value is selector-observable (:invalid / :in-range /
      # :placeholder-shown) with no attribute mutation behind it.
      @document&.__internal_note_value_change__
    end

    # `files` — for `<input type="file">`. Browsers populate this via
    # user interaction; in tests, code seeds it with `files=`.
    def files
      # `files` is null for every type other than file (WHATWG).
      return nil unless type == "file"

      @__files ||= FileList.new
    end

    # `input.files = …`: set the input's selected files — what a user's choice
    # gives it, through a driver (capybara-dommy's attach_file, Interaction's
    # file field) or a script (`input.files = dt.files`). Takes a FileList, or
    # an array of files to wrap in one.
    def files=(files_input)
      @__files = files_input.is_a?(FileList) ? files_input : FileList.new(Array(files_input))
    end

    # `input.files = dt.files` (the DataTransfer idiom) sets the file list.
    # `files` is otherwise read-only, so the shared setters never see it.
    def __js_set__(key, value)
      if key == "files"
        # `FileList?`: anything else is a TypeError. A null value, or an input
        # not in the File Upload state, leaves the selected files alone.
        raise Bridge::TypeError, "The provided value is not of type 'FileList'." unless value.nil? || value.is_a?(FileList)

        self.files = value unless value.nil? || type != "file"
        return nil
      end

      super
    end

    # The strategy for this control's `type`: what a number means here, and what
    # a step is worth. The sixteen `case type` branches that used to answer
    # these live in Internal::InputType, one class per type.
    def input_type = Internal::InputType.for(type)

    def value_as_number = input_type.value_of(value.to_s, self)

    # HTML: an infinite number is a TypeError before applicability is checked,
    # and NaN clears the value.
    def value_as_number=(number)
      number = Internal::WebIDL.unrestricted_double(number)
      raise Bridge::TypeError, "The value provided is infinite." if number.infinite?
      unless input_type.numeric?
        raise DOMException::InvalidStateError, "valueAsNumber is not applicable to input type '#{type}'"
      end

      self.value = number.nan? ? "" : input_type.from_number(number)
    end

    # The value as a UTC ::Time (a JS Date across the bridge), or nil when the
    # value is not a valid one or valueAsDate does not apply to the type.
    def value_as_date
      return nil unless input_type.date?

      time_value = input_type.to_date_value(value.to_s)
      ::Time.at(Rational(time_value.to_i, 1000)).utc if time_value.finite?
    end

    # Takes a Date (a ::Time or ::Date from Ruby) or nil; nil and an invalid
    # date clear the value. The IDL type is `object?`, so a primitive is a
    # TypeError before applicability is checked, and any other object one after.
    def value_as_date=(date)
      date = Internal::WebIDL.nullable_object!(date)
      unless input_type.date?
        raise DOMException::InvalidStateError, "valueAsDate is not applicable to input type '#{type}'"
      end

      time_value = date.nil? ? ::Float::NAN : Internal::WebIDL.date_time_value(date)
      raise Bridge::TypeError, "The value provided is not a Date." if time_value.nil?

      self.value = time_value.nan? ? "" : input_type.from_date_value(time_value)
    end

    # HTML's step base: the min content attribute as a number, else the value
    # content attribute as a number, else the type's default step base (a
    # week's), else zero.
    def validation_step_base
      step_boundary("min") || step_boundary("value") || input_type.step_base
    end

    def numeric_value_type? = input_type.numeric?

    def step_scale_factor = input_type.scale_factor

    def default_step = input_type.default_step

    def step_boundary(attr)
      raw = __internal_attribute_value__(attr).to_s.strip
      return nil if raw.empty?

      input_type.boundary(raw)
    end

    def sanitize_value(raw, state = type)
      strategy = Internal::InputType.for(state)
      case state
      # The one-line text types "strip newlines from the value" (WHATWG value
      # sanitization) — a pasted multi-line string collapses to one line.
      when "text", "search", "tel", "password"
        strip_newlines(raw.to_s)
      when "email"
        stripped = strip_newlines(raw.to_s)
        if __internal_has_attribute__?("multiple")
          stripped.split(",").map { |part| strip_ascii_whitespace(part) }.join(",")
        else
          strip_ascii_whitespace(stripped)
        end
      when "url"
        # Strip newlines, then leading/trailing whitespace.
        strip_ascii_whitespace(strip_newlines(raw.to_s))
      when "number", "date", "month", "week", "time"
        strategy.to_number(raw.to_s).finite? ? raw.to_s : ""
      when "range"
        strategy.from_number(strategy.value_of(raw.to_s, self))
      when "datetime-local"
        number = strategy.to_number(raw.to_s)
        number.finite? ? strategy.from_number(number) : ""
      when "color"
        sanitize_color(raw.to_s)
      else
        raw.to_s
      end
    end

    CSS_WHITESPACE = /\A[ \t\n\r\f]+|[ \t\n\r\f]+\z/
    SERIALIZED_RGB = /\Argba?\((\d+), (\d+), (\d+)(?:, [\d.e-]+)?\)\z/

    # HTML "update a color well control color" in the Limited sRGB state
    # without `alpha`: the value parsed as a CSS <color> (a named color,
    # #rgb / #rrggbb, rgb(), hsl(), …) and serialized as "#rrggbb", opaque
    # black when it does not parse. (The `alpha` and Display P3 serializations
    # are not modelled; they get the same hex form.)
    def sanitize_color(raw)
      text = raw.gsub(CSS_WHITESPACE, "")
      return "#000000" if text.empty? || text.match?(/[\u0000]/)

      match = SERIALIZED_RGB.match(Internal::CSS::Color.normalize(text))
      return "#000000" unless match

      format("#%02x%02x%02x", *match.captures.map { |c| c.to_i.clamp(0, 255) })
    end

    def strip_newlines(str)
      str.gsub(/[\r\n]/, "")
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

    # An input in an activatable state — every state but Hidden — has an
    # activation behavior; which one runs is decided from the state at
    # invocation (HTML's single input activation algorithm switches on `type`).
    # So a click listener that changes the type to submit still submits, while a
    # hidden input stays non-activating (a <label> forwards its click).
    def activation_target?
      type != "hidden"
    end

    # HTML "input activation behavior": a submit button submits its form, a reset
    # button resets it, and a checkbox / radio fires `input` then `change` — but
    # only when connected, so clicking a detached checkbox toggles it silently.
    # Both events are UA-generated, so trusted.
    def activation_behavior(event)
      input_activation_behavior
      # Then the popover target attribute activation behavior, unless a form
      # owns this control and it is not a plain button.
      return if form && type != "button"
      return if __internal_actually_disabled__

      run_popover_target_activation(event.__js_get__("target"))
    end

    # HTML's "input activation behavior" for the button-like and checkable
    # states.
    def input_activation_behavior
      return form&.__internal_run_form_submission__(self) if __internal_submit_button__?
      return form&.reset if type == "reset" && !disabled
      return unless CHECKABLE_TYPES.include?(type) && is_connected?

      dispatch_event(Event.new("input", "bubbles" => true).__internal_mark_trusted__)
      dispatch_event(Event.new("change", "bubbles" => true).__internal_mark_trusted__)
    end
    private :input_activation_behavior

    # HTML reset algorithm: drop the dirty value and dirty checkedness flags, so
    # `value` / `checked` fall back to the `value` / `checked` content attributes.
    def __internal_reset__
      @__value = nil
      @__value_dirty = false
      @__raw_value = nil
      @__user_raw_value = nil
      @__last_changed_by_user_edit = false
      @__files = FileList.new
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

    # Remember the current form owner; true when it differs from the one last
    # remembered (HTML's "form owner changes", which unchecks a radio's group).
    def __internal_note_form_owner__
      owner = form_owner
      changed = !same_form_owner?(owner, @__noted_form_owner)
      @__noted_form_owner = owner
      changed
    end

    # The radio button group: radios in the SAME tree (root node — so an orphan
    # subtree groups too) that share this element's non-empty name and form
    # owner (two radios with no form owner still group, as long as they share a
    # tree and name).
    def radio_group_members
      group_name = __internal_attribute_value__("name").to_s
      return [self] if group_name.empty?

      owner = form_owner
      root = get_root_node
      return [self] unless root.respond_to?(:query_selector_all)

      members = root.query_selector_all("input[type='radio']").to_a.select do |radio|
        next false unless radio.respond_to?(:form_owner)
        next false unless radio.__internal_attribute_value__("name").to_s == group_name

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
      value_as_number: "valueAsNumber", value_as_date: "valueAsDate",
      selection_start: "selectionStart", selection_end: "selectionEnd",
      selection_direction: "selectionDirection"
    js_readable :labels, :form, :files, :list

    SELECTION_TYPES = %w[text search url tel password].freeze

    # Only the one-line text types carry a selection; a checkbox or a number
    # spinner has none, and its setters raise (HTML "set the selection range").
    def supports_selection? = SELECTION_TYPES.include?(type)

    # Every attribute write path (IDL reflection, Attr, set/removeAttribute,
    # including NS variants) reaches this hook with the old attribute value.
    def __internal_attribute_changed__(name, old_value, new_value, namespace)
      super
      return unless namespace.nil?

      case name
      when "type"
        previous = enumerated_state_keyword(old_value, TYPE_STATES)
        change_type_state(previous) if previous != type
      when "value"
        if value_mode(type) == :value && !@__value_dirty
          @__value = sanitize_value(new_value.to_s)
          @__raw_value = nil
        end
      when "min", "max", "step", "multiple"
        @__value = sanitize_value(current_value) if value_mode(type) == :value
      when "name", "form"
        # A checked radio whose name or form owner changes unchecks the rest
        # of its new radio button group.
        __internal_note_form_owner__
        uncheck_radio_group if type == "radio" && checked
      end
      nil
    end

    # A user's edit (a driver typing into the field): the value is set as a
    # script would set it, but HTML then knows the value was last changed by
    # a user edit (tooLong / tooShort apply) and what the user typed before
    # sanitization (an unparseable number is bad input).
    def __internal_user_edit_value__(raw)
      self.value = raw
      @__user_raw_value = raw.to_s
      @__last_changed_by_user_edit = true
    end

    def __internal_user_raw_value__ = @__user_raw_value
    def __internal_last_changed_by_user_edit__ = @__last_changed_by_user_edit && @__value_dirty ? true : false

    # HTML `showPicker()`: an immutable control is an InvalidStateError, and
    # without transient activation — which Dommy, having no user, never has —
    # a NotAllowedError.
    def show_picker
      raise DOMException::InvalidStateError, "The input is not mutable." unless validity.host_mutable?

      raise DOMException::NotAllowedError, "showPicker() requires a user gesture."
    end

    # setRangeText's edit of the relevant value: it sets the dirty value flag.
    def __internal_set_relevant_value__(string)
      @__raw_value = string
      @__value = sanitize_value(string)
      @__value_dirty = true
      @document&.__internal_note_value_change__
    end










    # The declared step (default 1 for number, 1 for range); "any" disables
    # stepping (returns nil).
    def step_base_value
      raw = __internal_attribute_value__("step").to_s.strip
      return nil if raw.casecmp?("any")

      s = (Float(raw) rescue nil)
      s && s > 0 ? s : default_step
    end

    # HTML's stepUp(n) / stepDown(n). They throw when the type has no
    # allowed value step (no number representation, or step="any"). A value
    # that is not a number starts from 0; one off the step grid first snaps to
    # the nearest aligned value in the direction of the call (n is not used
    # then); otherwise it moves n steps. The result is pulled inside min/max
    # onto the grid, and a call that would move the value against its own
    # direction does nothing.
    def apply_step(count, direction)
      unless numeric_value_type?
        raise DOMException::InvalidStateError, "stepUp/stepDown is not applicable to input type '#{type}'"
      end

      step = allowed_value_step
      if step.nil?
        raise DOMException::InvalidStateError, "stepUp/stepDown is not allowed when step is 'any'"
      end

      # The arithmetic runs on the decimal values the attributes spell, not on
      # their nearest doubles: 0.1 + 0.1 + 0.1 is 0.3, not 0.30000000000000004.
      step = decimal(step)
      base = decimal(validation_step_base)
      mn = step_minimum
      mx = step_maximum
      mn = decimal(mn) if mn
      mx = decimal(mx) if mx
      return if mn && mx && mn > mx
      return if mn && mx && aligned_at_or_above(mn, base, step) > mx

      current = value_as_number
      value = current.nan? ? 0r : decimal(current)
      before = value
      offset = (value - base) / step
      if offset.denominator != 1
        value = base + (direction.positive? ? offset.ceil : offset.floor) * step
      else
        value += step * count * direction
      end
      value = aligned_at_or_above(mn, base, step) if mn && value < mn
      value = base + ((mx - base) / step).floor * step if mx && value > mx
      return if direction.negative? ? value > before : value < before

      self.value = input_type.from_number(value.to_f)
      nil
    end

    # The smallest value on the step grid at or above `limit`.
    def aligned_at_or_above(limit, base, step)
      base + ((limit - base) / step).ceil * step
    end

    # The minimum / maximum stepping respects: the attribute, or a range's
    # default minimum 0 and maximum 100.
    def step_minimum = min_as_number || (type == "range" ? 0.0 : nil)
    def step_maximum = max_as_number || (type == "range" ? 100.0 : nil)

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


    # `stepUp(optional long n = 1)` / `stepDown(…)`: a missing or undefined n
    # is 1, anything else converts as WebIDL's long.
    def step_up(n = 1)
      apply_step(step_count(n), 1)
    end

    def step_down(n = 1)
      apply_step(step_count(n), -1)
    end

    def step_count(n)
      n.equal?(Bridge::UNDEFINED) ? 1 : Internal::WebIDL.long(n)
    end

    # Barred from constraint validation, besides the shared reasons: the
    # Hidden, Reset Button and Button states, and a `readonly` attribute —
    # HTML's readonly section bars "an input element" it is specified on,
    # whatever the type (a readonly color or file input too). A submit or
    # image button is a submittable element like any other, and validates
    # (with no constraint of its own beyond a custom error).
    def __internal_barred_from_constraint_validation__?
      super || %w[hidden button reset].include?(type) || __internal_has_attribute__?("readonly")
    end

    # HTML "cloning steps" for input: the dirty value flag + value and the dirty
    # checkedness flag + checkedness (plus indeterminate) — the user-modified
    # state a clone must retain beyond the default* content attributes. The
    # sanitized current value and dirty flag must be copied independently.
    def __internal_cloning_state__
      state = {}
      state[:value] = @__value unless @__value.nil?
      state[:value_dirty] = true if @__value_dirty
      state[:raw_value] = @__raw_value unless @__raw_value.nil?
      state[:checked] = @__checked unless @__checked.nil?
      state[:indeterminate] = @__indeterminate unless @__indeterminate.nil?
      merge_cloning_state(super, state)
    end

    def __internal_apply_cloning_state__(state)
      super
      @__value = state[:value] if state.key?(:value)
      @__value_dirty = true if state[:value_dirty]
      @__raw_value = state[:raw_value] if state.key?(:raw_value)
      @__checked = state[:checked] if state.key?(:checked)
      @__indeterminate = state[:indeterminate] if state.key?(:indeterminate)
    end

    # HTMLInputElement.list — the <datalist> referenced by the `list` content
    # attribute (resolved by id, first element in tree order). Null when there
    # is no `list` attribute, no element with that id, or the referenced element
    # is not a <datalist>.
    def list
      id = __internal_attribute_value__("list")
      return nil if id.nil? || id.empty?

      # The first element with that ID in the input's own tree — a detached
      # subtree or a shadow tree included.
      element = __internal_tree_element_by_id__(id)
      element.is_a?(HTMLDataListElement) ? element : nil
    end


    js_methods %w[select setSelectionRange setRangeText stepUp stepDown showPicker]
    def __js_call__(method, args)
      case method
      when "select"
        select
      when "setSelectionRange"
        set_selection_range(args[0], args[1], args[2])
      when "setRangeText"
        __internal_js_set_range_text__(args)
      when "stepUp"
        args.empty? ? step_up : step_up(args[0])
      when "stepDown"
        args.empty? ? step_down : step_down(args[0])
      when "showPicker"
        show_picker
      else
        super
      end
    end

    private

    def strip_ascii_whitespace(str)
      str.gsub(/\A[\x09-\x0d ]+|[\x09-\x0d ]+\z/, "")
    end

    def require_selection!
      return if supports_selection?

      raise DOMException::InvalidStateError,
        "The input element's type ('#{type}') does not support selection."
    end

    def value_mode(state)
      case state
      when "hidden", "submit", "image", "reset", "button" then :default
      when "checkbox", "radio" then :default_on
      when "file" then :filename
      else :value
      end
    end

    def current_value(state = type)
      @__value ||= sanitize_value(default_value, state)
    end

    # Value modes, rather than individual type pairs, decide the transfer of
    # current value to/from the default. Pristine controls re-read their default
    # under the new state without making a sanitized fallback dirty.
    def change_type_state(previous)
      old_mode = value_mode(previous)
      new_mode = value_mode(type)
      if old_mode == :value && %i[default default_on].include?(new_mode)
        old_value = current_value(previous)
        self.default_value = old_value unless old_value.empty?
      elsif old_mode != :value && new_mode == :value
        @__value_dirty = false
      end

      if new_mode == :value
        raw = @__value_dirty ? current_value(previous) : default_value
        @__value = sanitize_value(raw)
      else
        @__value = nil
      end
      @__raw_value = nil
      @__files = FileList.new if new_mode == :filename
      uncheck_radio_group if type == "radio" && checked
      reset_selection_on_type_change(previous)
    end

    # HTML: a type change that makes the selection APIs apply puts the text
    # entry cursor at the beginning, with direction "none".
    def reset_selection_on_type_change(previous)
      __internal_reset_selection__ if supports_selection? && !SELECTION_TYPES.include?(previous)
    end
  end

  # `<button>` — type defaults to "submit" per spec.

  # `<button>` — type defaults to "submit" per spec.
end
