# frozen_string_literal: true

module Dommy
  # The form and its controls: what a user fills in and what a form submits.
  #
  # One of the HTML element groups; html_elements.rb lists them all.
  # `<form>` — element collection, submit/reset, and a stubbed
  # validation surface.
  class HTMLFormElement < HTMLElement
    reflect_string :name, :action, :enctype, :target, :autocomplete, method_attr: { attr: "method", js: "method" }, accept_charset: "accept-charset"
    reflect_boolean no_validate: "novalidate"
    # Own __js_call__ methods, on top of Element's.

    # `form.elements` — listed elements inside the form (excludes
    # nested forms per spec; we approximate by walking
    # input/select/textarea/button/output/fieldset). Returned as a
    # live HTMLCollection so listening to `submit`/`reset` and
    # adding fields between accesses works as expected.
    # `form.elements` — the listed controls owned by this form, in document tree
    # order, excluding input type=image. Membership follows the WHATWG form-owner
    # algorithm (a `form` content attribute overrides DOM nesting), NOT plain
    # descendant containment, so controls associated via `form=id` are included
    # and a control in a nested inner form is excluded. Memoized so the live
    # collection is the [SameObject] each access returns.
    LISTED_CONTROL_SELECTOR = "input, select, textarea, button, output, fieldset, object"

    # Events a form swallows rather than letting them reach its own listeners
    # when they were fired at another node — see the dispatch hook below.
    LEGACY_STOPPED_EVENTS = %w[submit reset].freeze

    # HTML's legacy form dispatch rule: a form does not see a `submit` or `reset`
    # event that was fired at a different node; the event stops here instead,
    # without running this form's listeners. What it is for is nested forms —
    # the parser never produces one, but the DOM API lets you build one, and
    # this is what keeps submitting an inner form from also running the outer
    # form's `onsubmit`. Capture is exempt: dispatch only consults this hook
    # once the event is at or past its target, so the event still reaches it.
    def __internal_legacy_stops_propagation__(event)
      return false unless LEGACY_STOPPED_EVENTS.include?(event.type)

      target = event.__js_get__("target")
      return false if target.nil?
      return false if target.respond_to?(:__dommy_backend_node__) && target.__dommy_backend_node__ == @__node__

      true
    end

    def elements
      el = self
      @elements ||= HTMLFormControlsCollection.new do
        # The form's own TREE is the search scope, so a control associated by a
        # `form=` attribute from outside the subtree is still found while one in
        # another tree — a shadow tree, or the light DOM around one — is not.
        scope = el.get_root_node || el
        scope.query_selector_all(LISTED_CONTROL_SELECTOR).select do |c|
          next false if c.tag_name.to_s.casecmp?("input") && c.respond_to?(:type) && c.type.to_s.casecmp?("image")

          el.__owns_control__(c)
        end
      end
    end

    # The form owner of a listed control, per WHATWG: when the control carries a
    # `form` content attribute, its owner is the form element with that id (or
    # nothing, if the id resolves to a non-form / nothing); otherwise it is the
    # nearest ancestor form element.
    def __owns_control__(control)
      owner = control.respond_to?(:__internal_form_owner__) ? control.__internal_form_owner__ : control.closest("form")
      !owner.nil? && owner.__dommy_backend_node__.equal?(__dommy_backend_node__)
    end

    def length
      elements.size
    end

    # Spec: `submit()` performs form submission directly WITHOUT firing a
    # `submit` event and without constraint validation. Navigation is handed to
    # the delegate (a no-op recording by default).
    def submit
      __internal_navigate_for_submit__(nil)
      nil
    end

    # HTML "reset a form": fire a cancelable `reset` event, and unless it was
    # prevented, run every resettable control's reset algorithm — which drops the
    # dirty value / checkedness so the control reverts to its content attributes.
    def reset
      reset_event = Event.new("reset", "bubbles" => true, "cancelable" => true).__internal_mark_trusted__
      return false unless dispatch_event(reset_event)

      elements.to_a.each { |control| control.__internal_reset__ if control.respond_to?(:__internal_reset__) }
      true
    end

    # Spec: `requestSubmit(submitter?)` MIRRORS user-initiated submission — it
    # fires a `submit` event (with the submitter), and on a non-canceled event
    # hands the form navigation to the delegate. Returns true if not
    # default-prevented. `submitter` (if given) must be a submit button inside
    # this form.
    def request_submit(submitter = nil)
      if submitter
        unless submitter.respond_to?(:__dommy_backend_node__) && submitter.__dommy_backend_node__.ancestors.include?(@__node__)
          raise DOMException::NotFoundError, "submitter is not a descendant of this form"
        end

        type = submitter.respond_to?(:type) ? submitter.type.to_s.downcase : ""
        unless %w[submit image].include?(type)
          raise TypeError, "submitter must be a submit button"
        end
      end

      __run_form_submission__(submitter)
    end

    # The form submission algorithm's observable core, shared by
    # `requestSubmit()`, a submit button's activation (driver click), and Enter's
    # implicit submission: fire a cancelable `SubmitEvent` (carrying the
    # submitter), and — when nothing canceled it — hand the resulting navigation
    # to the delegate. Returns true if not default-prevented. This is the single
    # home for "a form was submitted"; callers that previously dispatched a bare
    # `submit` event route here so the event is a real SubmitEvent (with
    # submitter) and the navigation reaches the delegate.
    def __run_form_submission__(submitter = nil)
      # HTML form submission: "if form cannot navigate, then return" — a form
      # that is not connected has no navigable, so clicking its submit button
      # fires nothing at all.
      return false unless is_connected?

      not_canceled = dispatch_event(
        SubmitEvent.new("submit", "bubbles" => true, "cancelable" => true, "submitter" => submitter)
      )
      __internal_navigate_for_submit__(submitter) if not_canceled
      not_canceled
    end

    # Build the form data set and hand the resulting navigation to the delegate.
    # Reuses the core FormSubmission serializer (submitter, method, action,
    # enctype, GET query-stripping) — method-override is a host concern, so it's
    # left off here (the delegate applies its own policy).
    def __internal_navigate_for_submit__(submitter)
      win = @document&.default_view
      return if win.nil?

      result = Dommy::Interaction::FormSubmission.new(self, submitter).submit!
      win.__internal_navigate__(
        url: result[:url], method: result[:method], params: result[:params],
        enctype: result[:enctype], source: :form
      )
    end

    # Walk all listed elements; the form is "valid" iff every
    # candidate control passes its own checkValidity. Dispatches a
    # non-bubbling `invalid` event on each failing control.
    def check_validity
      ok = true
      elements.each do |el|
        next unless el.respond_to?(:will_validate)
        next unless el.will_validate
        next if el.validity.valid && (el.instance_variable_get(:@custom_validity_message) || "").empty?

        # Fire invalid event on this control (matches spec).
        el.dispatch_event(Event.new("invalid", "bubbles" => false, "cancelable" => true))
        ok = false
      end

      ok
    end

    def report_validity
      check_validity
    end

    def __js_get__(key)
      # HTMLFormElement is [LegacyOverrideBuiltIns]: a control whose name/id
      # matches a builtin (`elements`, `length`, `submit`, `action`, …) shadows
      # that builtin. So the named getter is consulted BEFORE the builtins.
      name = key.to_s
      named = named_controls[name]
      if named && !named.empty?
        remember_past_name(name, named.first) if named.length == 1
        return __named_getter_result__(name, named)
      end
      past = past_named_control(name)
      return past if past

      case key
      when "elements"
        elements
      when "length"
        length
      else
        super
      end
    end

    # HTML's "past names map": the named getter remembers the single control it
    # last returned under a name, so a control that is later renamed — or loses
    # its name and id entirely — stays reachable under the old one. The entry
    # lives only as long as the control still belongs to this form; removing it
    # from the form, or pointing it at another one, drops the name.
    def remember_past_name(name, element)
      (@__past_names__ ||= {})[name] = element
      nil
    end

    def past_named_control(name)
      entry = @__past_names__&.[](name)
      return nil if entry.nil?
      return entry if own_control?(entry)

      @__past_names__.delete(name)
      nil
    end

    def own_control?(element)
      return false unless element.respond_to?(:__dommy_backend_node__)

      node = element.__dommy_backend_node__
      elements.any? { |el| el.respond_to?(:__dommy_backend_node__) && el.__dommy_backend_node__.equal?(node) }
    end

    # A single matching control is returned directly; multiple matches yield a
    # RadioNodeList. The list is memoized per name and refreshed in place so
    # repeated named-getter reads return the [SameObject] (WebIDL requires
    # `form.d === form.d`), while still reflecting live membership.
    def __named_getter_result__(name, matches)
      return matches.first if matches.length == 1

      form = self
      (@__radio_lists ||= {})[name] ||= RadioNodeList.new { form.named_controls[name] || [] }
    end

    # WebIDL named getter: the form's supported property names are the name/id
    # of each of its listed controls, followed by the names in its past names
    # map that still point at one of them.
    def __js_named_props__
      live = named_controls.keys
      past = (@__past_names__ || {}).keys.select { |name| past_named_control(name) }
      live + (past - live)
    end

    # name/id -> [controls], for the named getter (a name matching more than one
    # control yields a RadioNodeList-like NodeList).
    def named_controls
      map = ::Hash.new { |h, k| h[k] = [] }
      elements.each do |el|
        next unless el.respond_to?(:__dommy_backend_node__)

        node = el.__dommy_backend_node__
        name = node["name"].to_s
        map[name] << el unless name.empty?
        id = node["id"].to_s
        map[id] << el unless id.empty? || id == name
      end
      map
    end

    js_methods %w[submit reset requestSubmit checkValidity reportValidity]
    def __js_call__(method, args)
      case method
      when "submit"
        submit
      when "reset"
        reset
      when "requestSubmit"
        request_submit(args[0])
      when "checkValidity"
        check_validity
      when "reportValidity"
        report_validity
      else
        super
      end
    end
  end

  # `<input>` — covers the most-used form control surface.

  # `<input>` — covers the most-used form control surface.
  class HTMLInputElement < HTMLElement
    include SubmitButtonActivation
    include FormActionUrl
    reflect_string :name, :placeholder, :min, :max, :step, :pattern, :autocomplete, default_value: "value",
                   form_enctype: "formenctype", form_method: "formmethod", form_target: "formtarget"
    reflect_boolean :autofocus, :disabled, :required, :readonly, default_checked: "checked",
                    form_no_validate: "formnovalidate"
    # Own __js_call__ methods, on top of Element's.
    def type
      raw = @__node__["type"].to_s
      raw.empty? ? "text" : raw.downcase
    end

    def __submit_button__? = %w[submit image].include?(type) && !disabled

    def type=(v)
      set_reflected_string("type", v)
    end

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

    def value_as_number = input_type.to_number(value.to_s, self)

    def value_as_number=(number)
      self.value = input_type.from_number(number.to_f, self)
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
    js_accessor :type, :value, :checked, :indeterminate,
      value_as_number: "valueAsNumber",
      selection_start: "selectionStart", selection_end: "selectionEnd",
      selection_direction: "selectionDirection",
      max_length: "maxLength", min_length: "minLength",
      readonly: %w[readonly readOnly]
    js_readable :labels, :form, :validity, :files, :list,
      will_validate: "willValidate", validation_message: "validationMessage"

    SELECTION_TYPES = %w[text search url tel password].freeze

    def supports_selection?
      SELECTION_TYPES.include?(type)
    end

    def selection_start
      return nil unless supports_selection?

      @__selection_start ||= value.to_s.length
    end

    def selection_start=(v)
      require_selection!
      @__selection_start = clamp_selection_index(v)
    end

    def selection_end
      return nil unless supports_selection?

      @__selection_end ||= value.to_s.length
    end

    def selection_end=(v)
      require_selection!
      @__selection_end = clamp_selection_index(v)
    end

    def selection_direction
      return nil unless supports_selection?

      @__selection_direction || "none"
    end

    def selection_direction=(v)
      require_selection!
      @__selection_direction = normalize_selection_direction(v)
    end

    # `select()` selects the whole control on a text control; on any other type
    # it is a silent no-op (it does NOT throw).
    def select
      return nil unless supports_selection?

      @__selection_start = 0
      @__selection_end = value.to_s.length
      @__selection_direction = "none"
      nil
    end

    def set_selection_range(start, finish, direction = nil)
      require_selection!
      len = value.to_s.length
      e = clamp_selection_index(finish, len)
      s = [clamp_selection_index(start, len), e].min
      @__selection_start = s
      @__selection_end = e
      @__selection_direction = normalize_selection_direction(direction)
      nil
    end

    def set_range_text(_replacement, *_)
      require_selection!
      nil
    end

    # Raise on the selection setters/methods for a type that has no text
    # selection (email, number, checkbox, …).
    def require_selection!
      return if supports_selection?

      raise DOMException::InvalidStateError, "The input element's type ('#{type}') does not support selection."
    end

    def clamp_selection_index(v, len = value.to_s.length)
      n = v.to_i
      n.negative? ? 0 : [n, len].min
    end

    def normalize_selection_direction(v)
      d = v.to_s
      %w[forward backward].include?(d) ? d : "none"
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
  class HTMLButtonElement < HTMLElement
    include SubmitButtonActivation
    reflect_string :name, form_enctype: "formenctype", form_method: "formmethod", form_target: "formtarget"
    reflect_boolean :disabled, :autofocus, form_no_validate: "formnovalidate"
    include FormActionUrl

    def type
      raw = @__node__["type"].to_s.downcase
      %w[submit reset button].include?(raw) ? raw : "submit"
    end

    def __submit_button__? = type == "submit" && !disabled

    # A reset button has activation behavior of its own, on top of the
    # submit-button behavior inherited from SubmitButtonActivation.
    def activation_target?
      super || (type == "reset" && !disabled)
    end

    def activation_behavior(event)
      return super if __submit_button__?

      form&.reset if type == "reset" && !disabled
    end

    def type=(v)
      set_reflected_string("type", v)
    end

    # The form owner: a `form=` attribute pointing at a form (form-associated
    # element, so a button can live outside its form), else the nearest ancestor
    # form.
    def form
      __internal_form_owner__
    end

    def labels
      labels_node_list
    end

    def validity
      @__validity ||= ValidityState.new(self)
    end

    # Only a submit button is a candidate for constraint validation; reset /
    # button types are barred, as are disabled controls and datalist descendants.
    def will_validate
      type == "submit" && !disabled && !disabled_by_ancestor_fieldset? && closest("datalist").nil?
    end

    # A button has no constraints of its own, so the only thing it can report is
    # a message set through setCustomValidity — and only while it validates.
    def validation_message
      return "" unless will_validate

      (@custom_validity_message || "").to_s
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

    def __js_get__(key)
      case key
      when "type"
        type
      when "form"
        form
      when "labels"
        labels
      when "validity"
        validity
      when "willValidate"
        will_validate
      when "validationMessage"
        validation_message
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "type"
        set_reflected_string("type", value)
      else
        super
      end
    end

    js_methods %w[checkValidity reportValidity setCustomValidity]
    def __js_call__(method, args)
      case method
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

  # `<img>` — reflected URL/dimension attributes. Dommy has no real
  # image loading, so `complete`/`naturalWidth`/`naturalHeight` are
  # static (complete=true, dimensions=0).

  # `<option>` — value, label, selected, disabled, text, index, form.
  class HTMLOptionElement < HTMLElement
    reflect_boolean :disabled
    def value
      # `value`/`label` reflect the NO-namespace content attribute (a same-named
      # attribute in another namespace, via setAttributeNS, does not count);
      # both default to the option's `text` when their attribute is absent.
      has_attribute_ns?(nil, "value") ? get_attribute_ns(nil, "value").to_s : text
    end

    def value=(v)
      set_reflected_string("value", v)
    end

    def label
      has_attribute_ns?(nil, "label") ? get_attribute_ns(nil, "label").to_s : text
    end

    def label=(v)
      set_reflected_string("label", v)
    end

    # `defaultSelected` reflects the `selected` content attribute.
    def default_selected
      reflected_boolean("selected")
    end

    def default_selected=(v)
      set_reflected_boolean("selected", v)
    end

    # `selected` is the selectedness state. It is a distinct boolean (the IDL
    # getter returns it directly), initialised from defaultSelected. While the
    # dirtiness flag is false, adding/removing the `selected` content attribute
    # re-syncs selectedness to it; the IDL setter makes it dirty so it then holds
    # its value independently of the attribute.
    def selected
      @selectedness = default_selected if @selectedness.nil?
      @selectedness
    end

    # IDL setter: set selectedness, mark it dirty, then ask the owning select
    # for a reset (its selectedness setting algorithm).
    def selected=(value)
      @selectedness_dirty = true
      __internal_set_selectedness__(value)
      ask_for_reset
    end

    # Set selectedness without touching dirtiness (the Option constructor's
    # step, the `selected` attribute while not dirty). HTML: in a select
    # without `multiple`, an option whose selectedness becomes true sets every
    # other option's to false — right away, before any reset runs, so the
    # option just set is the one that survives.
    def __internal_set_selectedness__(value)
      __internal_write_selectedness__(value)
      owner = __internal_owner_select__
      owner.__internal_deselect_others__(self) if @selectedness && owner && !owner.multiple
      nil
    end

    # The bare write, with no cross-option rule: the owning select's bulk
    # setters (value=, selectedIndex=) and its selectedness setting algorithm
    # keep the list consistent themselves. `dirty:` is for those setters' one
    # chosen option — HTML has them set its dirtiness too, so the `selected`
    # attribute stops driving it from then on.
    def __internal_write_selectedness__(value, dirty: false)
      @selectedness = !!value
      @selectedness_dirty = true if dirty
      note_selectedness_change
    end

    # HTML reset algorithm (run for each option by the owning select, which then
    # settles the list): clear the dirtiness flag and re-sync selectedness to
    # the `selected` content attribute.
    def __internal_reset__
      @selectedness_dirty = false
      __internal_write_selectedness__(default_selected)
    end

    # The select whose list of options this option is in — nil while detached.
    # Matches HTMLSelectElement#options, which collects every descendant option.
    def __internal_owner_select__
      owner = closest("select")
      owner.is_a?(HTMLSelectElement) ? owner : nil
    end

    # HTML's attribute change steps for an option: while not dirty, selectedness
    # follows the `selected` content attribute.
    def __internal_attribute_changed__(name, _old_value, _new_value, namespace)
      return nil unless namespace.nil? && name.casecmp?("selected")

      sync_selectedness_from_attribute
      nil
    end

    # The `selected` content attribute came or went: while not dirty,
    # selectedness follows it. HTML's attribute steps stop there; browsers then
    # also reset the list (removing the attribute from the only selected option
    # of a single-select re-selects the first option), so ask for one.
    def sync_selectedness_from_attribute
      return if @selectedness_dirty

      __internal_set_selectedness__(default_selected)
      ask_for_reset
    end

    def text
      # WHATWG: strip-and-collapse ASCII whitespace over the concatenated Text
      # node descendants — excluding any inside a script (HTML or SVG) element.
      parts = []
      collect_option_text(@__node__, parts)
      parts.join.gsub(/[\t\n\f\r ]+/, " ").strip
    end

    def text=(v)
      self.text_content = v
    end

    # HTML's "disabled" concept for an option: the attribute on the option
    # itself, or on the optgroup it sits in. Asked by the owning select when it
    # looks for the first option it may select.
    def __internal_disabled_for_selection__
      return true if disabled

      parent = parent_element
      parent.is_a?(HTMLOptGroupElement) && parent.disabled
    end

    private

    # Selectedness is property state (no attribute mutation announces it), yet
    # it is selector-observable twice over: as this option's :checked, and as
    # the owning select's value behind :invalid / :valid. Every selectedness
    # writer funnels here — `select.value=` and `selected_index=` included,
    # since they set each option's selectedness — so the caches are invalidated
    # exactly as a checkbox's `checked=` invalidates them.
    def note_selectedness_change
      @document&.__internal_note_selector_state_change__
      nil
    end

    # HTML "ask for a reset": the owning select runs its selectedness setting
    # algorithm over the whole list.
    def ask_for_reset
      __internal_owner_select__&.__internal_settle_selectedness__
      nil
    end

    def collect_option_text(node, parts)
      node.children.each do |child|
        if child.text?
          parts << child.content
        elsif child.element? && !excluded_from_option_text?(child)
          collect_option_text(child, parts)
        end
      end
    end

    # Per spec, option.text skips the descendants of an HTML/SVG `script` and an
    # HTML `style` element — but NOT a same-named element in another namespace
    # (a MathML or null-namespace `<script>` still contributes its text).
    def excluded_from_option_text?(node)
      name = node.name.to_s.downcase
      return false unless %w[script style].include?(name)

      el = @document.wrap_node(node)
      ns = el.respond_to?(:namespace_uri) ? el.namespace_uri : nil
      html = Internal::Namespaces::HTML
      svg = Internal::Namespaces::SVG
      name == "script" ? [html, svg].include?(ns) : ns == html
    end

    public

    def form
      closest("form")
    end

    # `index` — position within the containing select's options list.
    def index
      sel = closest("select")
      return 0 unless sel

      sel.options.find_index { |o| o.__dommy_backend_node__ == @__node__ } || 0
    end

    def __js_get__(key)
      case key
      when "value"
        value
      when "label"
        label
      when "defaultSelected"
        default_selected
      when "selected"
        selected
      when "text"
        text
      when "form"
        form
      when "index"
        index
      else
        super
      end
    end

    def __js_set__(key, v)
      case key
      when "value"
        self.value = v
      when "label"
        self.label = v
      when "selected"
        self.selected = v
      when "defaultSelected"
        self.default_selected = v
      when "text"
        self.text = v
      else
        super
      end
    end
  end

  # `<optgroup>` — label + disabled, container for options.

  # `<optgroup>` — label + disabled, container for options.
  class HTMLOptGroupElement < HTMLElement
    reflect_string :label
    reflect_boolean :disabled
  end

  # `<textarea>` — multi-line text input.

  # `<textarea>` — multi-line text input.
  class HTMLTextAreaElement < HTMLElement
    reflect_string :name, :placeholder, :wrap, :autocomplete
    # Own __js_call__ methods, on top of Element's.

    # The API value is the "raw value" — the dirty value once set (a wrapper-level
    # flag, NOT a content attribute, so `setAttribute("value", …)` can't touch it),
    # otherwise the default value (the element's child text content).
    def value
      @__value_dirty ? @__value.to_s : default_value
    end

    def value=(v)
      @__value = v.to_s
      @__value_dirty = true
      @document&.__internal_note_value_change__
    end

    # HTML reset algorithm: clear the dirty value flag so `value` reverts to the
    # child text content.
    def __internal_reset__
      @__value = nil
      @__value_dirty = false
      @document&.__internal_note_value_change__
      nil
    end

    # defaultValue is the child text content; setting it (or `text`) leaves the
    # dirty value flag alone.
    def default_value
      text_content
    end

    def default_value=(v)
      self.text_content = v
    end

    # HTML cloning steps: copy the dirty value flag + raw value so a clone keeps
    # the user-entered text rather than reverting to the default (child text).
    def __cloning_state__
      @__value_dirty ? { value: @__value, dirty: true } : nil
    end

    def __apply_cloning_state__(state)
      return unless state[:dirty]

      @__value = state[:value]
      @__value_dirty = true
    end

    def rows
      (@__node__["rows"] || "2").to_i
    end

    def rows=(v)
      set_reflected_string("rows", v.to_s)
    end

    def cols
      (@__node__["cols"] || "20").to_i
    end

    def cols=(v)
      set_reflected_string("cols", v.to_s)
    end

    # `maxLength` / `minLength` reflect a "limited to only non-negative numbers"
    # long: a missing / negative / non-numeric content attribute is -1.
    def max_length
      parse_non_negative_reflected("maxlength")
    end

    def min_length
      parse_non_negative_reflected("minlength")
    end

    def max_length=(value)
      set_non_negative_reflected("maxlength", value)
    end

    def min_length=(value)
      set_non_negative_reflected("minlength", value)
    end

    private

    public

    def text_length
      value.length
    end

    def type
      "textarea"
    end

    def form
      closest("form")
    end

    def labels
      labels_node_list
    end

    # No real selection — same stub story as input.
    def select
      nil
    end

    def set_selection_range(_s, _e, _direction = nil)
      nil
    end

    def set_range_text(_replacement, *_)
      nil
    end

    def validity
      @__validity ||= ValidityState.new(self)
    end

    def will_validate
      !reflected_boolean("disabled") && !disabled_by_ancestor_fieldset? &&
        !reflected_boolean("readonly") && closest("datalist").nil?
    end

    def validation_message
      return "" unless will_validate

      msg = (@custom_validity_message || "").to_s
      return msg unless msg.empty?
      return "Please fill out this field." if validity.value_missing

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

    def __js_get__(key)
      case key
      when "value"
        value
      when "defaultValue"
        default_value
      when "rows"
        rows
      when "cols"
        cols
      when "maxLength"
        max_length
      when "minLength"
        min_length
      when "textLength"
        text_length
      when "type"
        type
      when "form"
        form
      when "labels"
        labels
      when "validity"
        validity
      when "willValidate"
        will_validate
      when "validationMessage"
        validation_message
      else
        super
      end
    end

    def __js_set__(key, v)
      case key
      when "value"
        self.value = v
      when "defaultValue"
        self.default_value = v
      when "rows"
        self.rows = v
      when "cols"
        self.cols = v
      when "maxLength"
        self.max_length = v
      when "minLength"
        self.min_length = v
      else
        super
      end
    end

    js_methods %w[
      select setSelectionRange setRangeText checkValidity reportValidity setCustomValidity
    ]
    def __js_call__(method, args)
      case method
      when "select"
        select
      when "setSelectionRange"
        set_selection_range(args[0], args[1], args[2])
      when "setRangeText"
        set_range_text(args[0])
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
    # end HTMLTextAreaElement
  end

  # `<label>` — `htmlFor` IDL maps to the HTML `for` attribute;
  # `control` returns the labelled form control.

  # `<label>` — `htmlFor` IDL maps to the HTML `for` attribute;
  # `control` returns the labelled form control.
  class HTMLLabelElement < HTMLElement
    reflect_string html_for: "for"

    # HTML "interactive content" (§3.2.5.2.7): a click that landed on one of
    # these inside a label is NOT forwarded again by the label — the element
    # handles its own click. An input is interactive unless hidden; a, audio,
    # img and video only with the attribute that makes them so.
    INTERACTIVE_CONTENT = "a[href], audio[controls], button, details, embed, iframe, img[usemap], " \
                          "input:not([type=hidden i]), label, select, textarea, video[controls]"

    def activation_target?
      !control.nil?
    end

    # HTML: a label's activation behavior runs synthetic click activation steps
    # on its labeled control — which is what makes clicking a label's text check
    # the checkbox next to it. Browsers also move focus to the control first (a
    # label that stands in for a visually hidden submit input, Turbo's
    # confirmation flow for one, relies on it becoming the active element). A
    # click already targeted at interactive content *inside* the label (the
    # control itself included) is left alone, so the forwarded click cannot
    # bounce back here. Interactive content the label is nested in — a label
    # inside an <a> or a <button> — is not a descendant, so it does not suppress
    # the forwarding.
    def activation_behavior(_event)
      labeled = control
      return if labeled.nil?

      # The nearest interactive ancestor of the click's origin, this label
      # itself excluded: a label is interactive content too, so from a click
      # on its own text `closest` reaches it — that is the ordinary case, not a
      # nested interactive element to leave alone.
      origin = _event.__js_get__("target")
      interactive = origin.closest(INTERACTIVE_CONTENT) if origin.respond_to?(:closest)
      return if interactive && !interactive.equal?(self) && contains?(interactive)

      labeled.focus if labeled.respond_to?(:focus)
      labeled.click
    end
    # `label.control` — the form control associated with this label.
    # Priority: explicit `for=`, then first form control descendant.
    def control
      target = html_for
      if !target.empty?
        el = @document.get_element_by_id(target)
        el if el && labelable_control?(el)
      else
        # The first labelable descendant in tree order (a hidden input, being
        # non-labelable, is skipped).
        query_selector_all("button, input, meter, output, progress, select, textarea")
          .to_a.find { |c| labelable_control?(c) }
      end
    end

    # Labelable elements: button, input (except type=hidden), meter, output,
    # progress, select, textarea.
    def labelable_control?(el)
      tag = el.tag_name.to_s.downcase
      return el.type.to_s.downcase != "hidden" if tag == "input"

      %w[button meter output progress select textarea].include?(tag)
    end

    def form
      closest("form")
    end

    def __js_get__(key)
      case key
      when "control"
        control
      when "form"
        form
      else
        super
      end
    end
  end

  # `<fieldset>` — disabled-state-propagating wrapper; exposes
  # `elements` collection like form.

  # `<fieldset>` — disabled-state-propagating wrapper; exposes
  # `elements` collection like form.
  class HTMLFieldSetElement < HTMLElement
    reflect_string :name
    reflect_boolean :disabled
    def type
      "fieldset"
    end

    def form
      closest("form")
    end

    def elements
      el = self
      HTMLCollection.new do
        el
          .__dommy_backend_node__
          .css("input, select, textarea, button, output, fieldset")
          .map do |n|
            el.document.wrap_node(n)
          end
          .compact
      end
    end

    def validity
      ValidityState.new
    end

    # A fieldset is "barred from constraint validation": it never participates,
    # so willValidate is always false and checkValidity/reportValidity are no-ops
    # that report success.
    def will_validate
      false
    end

    def check_validity
      true
    end

    def report_validity
      true
    end

    def __js_get__(key)
      case key
      when "type"
        type
      when "form"
        form
      when "elements"
        elements
      when "validity"
        validity
      when "willValidate"
        will_validate
      else
        super
      end
    end

    js_methods %w[checkValidity reportValidity]
    def __js_call__(method, args)
      case method
      when "checkValidity"
        check_validity
      when "reportValidity"
        report_validity
      else
        super
      end
    end
  end

  # `<output>` — calculation result element.

  # `<output>` — calculation result element.
  class HTMLOutputElement < HTMLElement
    reflect_string :name

    # `value` is always the descendant text content. `defaultValue` tracks a
    # separate "default value override": while the value mode flag is "default"
    # the two coincide (setting either updates the text), but once `value=` flips
    # the flag to "value" they diverge — the override is frozen and further
    # `defaultValue=` no longer touches the text content.
    def value
      text_content
    end

    def value=(v)
      if @__value_mode != :value
        @__default_override = text_content
        @__value_mode = :value
      end
      self.text_content = v.to_s
    end

    def default_value
      @__value_mode == :value ? @__default_override.to_s : text_content
    end

    def default_value=(v)
      if @__value_mode == :value
        @__default_override = v.to_s
      else
        self.text_content = v.to_s
      end
    end

    # `for` attribute is a space-separated list of IDs.
    def html_for_tokens
      reflected_string("for").split(/\s+/).reject(&:empty?)
    end

    def form
      closest("form")
    end

    def labels
      labels_node_list
    end

    def type
      "output"
    end

    # An output has a validity state (customError is settable) but is barred
    # from constraint validation: willValidate is false, validationMessage is
    # always empty, and check/reportValidity always succeed.
    def validity
      @__validity ||= ValidityState.new(self)
    end

    def will_validate
      false
    end

    def validation_message
      ""
    end

    def check_validity
      true
    end

    def report_validity
      true
    end

    def set_custom_validity(msg)
      @custom_validity_message = msg.to_s
      nil
    end

    def __js_get__(key)
      case key
      when "value"
        value
      when "defaultValue"
        default_value
      when "type"
        type
      when "form"
        form
      when "labels"
        labels
      when "validity"
        validity
      when "willValidate"
        will_validate
      when "validationMessage"
        validation_message
      when "htmlFor"
        # `output.htmlFor` is a DOMTokenList (unlike `label.htmlFor`, a string).
        reflected_token_list("htmlFor", "for")
      else
        super
      end
    end

    def __js_set__(key, v)
      case key
      when "value"
        self.value = v
      when "defaultValue"
        self.default_value = v
      when "htmlFor"
        set_reflected_string("for", v)
      else
        super
      end
    end

    js_methods %w[checkValidity reportValidity setCustomValidity]
    def __js_call__(method, args)
      case method
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

  # `<legend>` — primarily exposes its `form` back-ref.

  # `<legend>` — primarily exposes its `form` back-ref.
  class HTMLLegendElement < HTMLElement
    def form
      fieldset = closest("fieldset")
      fieldset&.closest("form") || closest("form")
    end

    def __js_get__(key)
      key == "form" ? form : super
    end
  end

  # `<slot>` — composes light DOM into the shadow tree. Light DOM
  # children of the shadow's host get assigned to slots: those whose
  # `slot=name` attribute matches a named slot, or those without a
  # `slot` attribute go to the unnamed default slot. If nothing is
  # assigned, the slot's own children render as fallback content.

  # `<select>` — exposes `value` (selected option's value), `options`,
  # `selectedIndex`, and dispatches change events. Minimal compared to
  # happy-dom's full HTMLSelectElement, but covers common test cases.
  class HTMLSelectElement < HTMLElement
    reflect_string :name
    reflect_boolean :multiple
    # Own __js_call__ methods, on top of Element's.

    def size
      @__node__["size"].to_s.to_i
    end

    # HTML "display size": the `size` attribute when positive, else 4 for a
    # multiple select and 1 otherwise. Only at display size 1 does a list with
    # nothing selected fall back to its first option.
    def display_size
      n = size
      n.positive? ? n : (multiple ? 4 : 1)
    end

    # Attributes that decide which selectedness rules the list lives under.
    SELECTEDNESS_ATTRIBUTES = %w[multiple size].freeze

    # HTML's attribute change steps for a select: losing `multiple`, or a change
    # of `size`, changes which rules apply to the list, so settle it again.
    def __internal_attribute_changed__(name, _old_value, _new_value, namespace)
      return nil unless namespace.nil? && SELECTEDNESS_ATTRIBUTES.any? { |a| name.casecmp?(a) }

      __internal_settle_selectedness__
      nil
    end

    # `options` — all <option> descendants (including those inside
    # <optgroup>). Live HTMLOptionsCollection (HTMLCollection +
    # add/remove/selectedIndex/length= helpers).
    def options
      el = self
      HTMLOptionsCollection.new(self) do
        el.__dommy_backend_node__.css("option").map { |n| el.document.wrap_node(n) }.compact
      end
    end

    # `selectedOptions` — live collection of the options whose selectedness is
    # true (a settled single-select has at most one).
    def selected_options
      el = self
      @selected_options ||= HTMLCollection.new { el.__display_selected__ }
    end

    def length
      options.size
    end

    # `select.length = n` resizes the options list (delegates to the collection):
    # shrinks by removing trailing options, grows by appending blank ones.
    def length=(n)
      options.length = n
    end

    # `select.namedItem(name)` — the first option whose id or name matches.
    def named_item(name)
      options.named_item(name)
    end

    def form
      closest("form")
    end

    # The options whose selectedness is true. The list is kept consistent as
    # it changes (see #__internal_settle_selectedness__), so nothing is derived
    # here; a list the parser built is settled once, lazily, in case it was
    # never handed the parsed-document steps.
    def __display_selected__
      __internal_settle_selectedness_once__
      options.to_a.select { |o| o.respond_to?(:selected) && o.selected }
    end

    def selected_index
      opts = options.to_a
      sel = __display_selected__.first
      return -1 unless sel

      opts.find_index { |o| o.__dommy_backend_node__.equal?(sel.__dommy_backend_node__) } || -1
    end

    # `selectedIndex=`: every option's selectedness becomes false, then the one
    # at `i` (if any) becomes true and dirty — bare writes, no reset: an
    # out-of-range index leaves nothing selected, as in a browser.
    def selected_index=(i)
      target = i.to_i
      options.to_a.each_with_index do |o, idx|
        chosen = idx == target
        o.__internal_write_selectedness__(chosen, dirty: chosen)
      end
      nil
    end

    # HTML reset algorithm: reset every option's selectedness, then run the
    # selectedness setting algorithm — a single-selection select whose options
    # all lost their `selected` attribute falls back to its first option.
    def __internal_reset__
      options.to_a.each(&:__internal_reset__)
      __internal_settle_selectedness__
    end

    # HTML: in a select without `multiple`, "whenever an option element in the
    # select element's list of options has its selectedness set to true, set
    # the selectedness of all the other option elements to false".
    def __internal_deselect_others__(keep)
      keep_node = keep.__dommy_backend_node__
      options.to_a.each do |o|
        next if o.__dommy_backend_node__.equal?(keep_node)
        next unless o.respond_to?(:selected) && o.selected

        o.__internal_write_selectedness__(false)
      end
      nil
    end

    # The list of options gained or lost members. `arrived` is the options that
    # landed in it, in tree order (an arriving optgroup having already been
    # expanded into the options it carried). HTML: an option added to the list
    # with its selectedness already true sets every other option's to false — so
    # of several arriving selected, the last in tree order wins, wherever in the
    # list they landed — and then the list settles.
    def __internal_options_changed__(arrived)
      unless multiple
        winner = arrived.reverse_each.find { |option| option.respond_to?(:selected) && option.selected }
        __internal_deselect_others__(winner) if winner
      end
      __internal_settle_selectedness__
    end

    # A list that was never settled — the parser built it, in a document or a
    # fragment, and no mutation has touched it since — is settled now. A select
    # whose list was already settled is left alone: moving or inserting the
    # select itself changes nothing in its list of options, so an explicit
    # "nothing selected" (selectedIndex = -1) survives the move.
    def __internal_settle_selectedness_once__
      __internal_settle_selectedness__ unless @selectedness_settled
      nil
    end

    # The selectedness setting algorithm (HTML §4.10.7). Runs when the list of
    # options gains or loses members, when an option asks for a reset, on the
    # select's own reset, and when `multiple` / `size` change. Only for a select
    # without `multiple`: a list with nothing selected selects its first
    # non-disabled option (at display size 1 only); a list with several selected
    # keeps only the last of them in tree order.
    def __internal_settle_selectedness__
      @selectedness_settled = true
      return nil if multiple

      opts = options.to_a
      chosen = opts.select { |o| o.respond_to?(:selected) && o.selected }
      if chosen.empty?
        first = opts.find { |o| selectable?(o) } if display_size == 1
        first&.__internal_write_selectedness__(true)
      elsif chosen.length > 1
        chosen[0...-1].each { |o| o.__internal_write_selectedness__(false) }
      end
      nil
    end

    # `value` of the select = value of the (displayed) selected option, or "".
    def value
      sel = __display_selected__.first
      sel ? sel.value.to_s : ""
    end

    # `value=`: every option's selectedness becomes false, then the first whose
    # value matches (if any) becomes true and dirty — bare writes, no reset: a
    # value no option has leaves nothing selected, as in a browser.
    def value=(new_value)
      opts = options.to_a
      target = opts.find { |o| o.value.to_s == new_value.to_s }
      opts.each { |o| o.__internal_write_selectedness__(false) }
      target&.__internal_write_selectedness__(true, dirty: true)
      nil
    end

    # An option this select may settle on: one that is not disabled, itself or
    # through its optgroup. The option answers that; the select only asks.
    def selectable?(option)
      option.respond_to?(:__internal_disabled_for_selection__) &&
        !option.__internal_disabled_for_selection__
    end
    private :selectable?

    # `select.item(i)` — returns the option at index i.
    def item(i)
      options[i.to_i]
    end

    # `select.add(option, before)` — appends or inserts before `before`.
    def add(option, before = nil)
      return nil unless option.respond_to?(:__dommy_backend_node__)

      if before.respond_to?(:__dommy_backend_node__)
        insert_before(option, before)
      else
        append_child(option)
      end

      nil
    end

    # `select.remove(i)` — removes the option at index i. (Note: also
    # inherits `remove()` from ChildNode for self-removal; spec lets
    # both forms coexist via overloading.)
    def remove_option(i)
      idx = i.to_i
      # An index out of range (including a negative one) is a no-op — NOT Ruby's
      # from-the-end negative indexing.
      return if idx.negative? || idx >= options.length

      options[idx]&.remove
    end

    def labels
      labels_node_list
    end

    def type
      multiple ? "select-multiple" : "select-one"
    end

    def validity
      @__validity ||= ValidityState.new(self)
    end

    def will_validate
      !reflected_boolean("disabled") && !disabled_by_ancestor_fieldset? && closest("datalist").nil?
    end

    def validation_message
      return "" unless will_validate

      msg = (@custom_validity_message || "").to_s
      return msg unless msg.empty?
      return "Please select an item in the list." if validity.value_missing

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

    js_accessor :value, selected_index: "selectedIndex", length: "length"
    js_readable :options, :size, :form, :labels, :type, :validity,
      selected_options: "selectedOptions",
      will_validate: "willValidate", validation_message: "validationMessage"

    # Indexed getter: `select[i]` is the option at index i (WebIDL).
    def __js_get__(key)
      return item(key) if key.is_a?(Integer)
      return item(key.to_i) if key.is_a?(String) && key.match?(/\A\d+\z/)

      super
    end

    # Indexed setter: `select[i] = option` delegates to the options collection's
    # WebIDL "set an indexed property" algorithm.
    def __js_set__(key, val)
      if key.is_a?(Integer) || (key.is_a?(String) && key.match?(/\A\d+\z/))
        return options.__set_indexed__(key.to_i, val)
      end

      super
    end

    js_methods %w[item namedItem add remove checkValidity reportValidity setCustomValidity]
    def __js_call__(method, args)
      case method
      when "item"
        item(args[0])
      when "namedItem"
        named_item(args[0])
      when "add"
        add(args[0], args[1])
      when "remove"
        # HTMLSelectElement.remove(index) removes an option; with no argument it
        # is ChildNode.remove() (removes the <select> itself).
        args.empty? ? super : remove_option(args[0])
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

  # `<dialog>` — `open` reflected boolean, `show()` / `showModal()` /
  # `close(returnValue?)`. Dommy has no modal stack, so showModal is
  # functionally identical to show (no backdrop, no escape-to-close).

  # `<meter>` — gauge with `value` / `min` / `max` (default 0/0/1)
  # plus `low` / `high` / `optimum`. All numeric; `labels` via the
  # standard `<label for="...">` association.
  class HTMLMeterElement < HTMLElement
    # The IDL getters return the WHATWG "actual" values, constrained in order:
    # min → max (≥min) → value (∈[min,max]) → low (∈[min,max]) →
    # high (∈[low,max]) → optimum (∈[min,max]).
    def min
      numeric_attr("min", 0.0)
    end

    def min=(v)
      set_reflected_string("min", format_double(restricted_double(v)))
    end

    def max
      [numeric_attr("max", 1.0), min].max
    end

    def max=(v)
      set_reflected_string("max", format_double(restricted_double(v)))
    end

    def value
      clamp(numeric_attr("value", 0.0), min, max)
    end

    def value=(v)
      set_reflected_string("value", format_double(restricted_double(v)))
    end

    def low
      clamp(numeric_attr("low", min), min, max)
    end

    def low=(v)
      set_reflected_string("low", format_double(restricted_double(v)))
    end

    def high
      clamp(numeric_attr("high", max), low, max)
    end

    def high=(v)
      set_reflected_string("high", format_double(restricted_double(v)))
    end

    def optimum
      clamp(numeric_attr("optimum", (min + max) / 2.0), min, max)
    end

    def optimum=(v)
      set_reflected_string("optimum", format_double(restricted_double(v)))
    end

    def labels
      labels_node_list
    end

    def __js_get__(key)
      case key
      when "value"
        value
      when "min"
        min
      when "max"
        max
      when "low"
        low
      when "high"
        high
      when "optimum"
        optimum
      when "labels"
        labels
      else
        super
      end
    end

    def __js_set__(key, v)
      case key
      when "value" then self.value = v
      when "min" then self.min = v
      when "max" then self.max = v
      when "low" then self.low = v
      when "high" then self.high = v
      when "optimum" then self.optimum = v
      else super
      end
    end

    private

    def numeric_attr(name, default)
      raw = @__node__[name].to_s
      raw.empty? ? default : Float(raw) rescue default
    end

    def clamp(v, lo, hi)
      return lo if v < lo
      return hi if v > hi

      v
    end

    # WebIDL `double` conversion (ToNumber) for the meter's IDL setters: a value
    # that coerces to NaN/±Infinity — e.g. `meter.value = "foobar"` — is a
    # restricted double and throws a TypeError.
    def restricted_double(v)
      n =
        case v
        when Numeric then v.to_f
        when nil then 0.0
        when true then 1.0
        when false then 0.0
        when String then (v.strip.empty? ? 0.0 : (Float(v.strip) rescue ::Float::NAN))
        else ::Float::NAN
        end
      raise Bridge::TypeError, "The provided double value is non-finite." if n.nan? || n.infinite?

      n
    end

    # The "best representation" of a double for a reflected content attribute:
    # an integral value loses its trailing ".0".
    def format_double(n)
      n == n.to_i ? n.to_i.to_s : n.to_s
    end
  end

  # `<progress>` — `value` and `max` (default max=1). `position`
  # returns `value / max` for a "determinate" progress bar, or -1
  # when no value is set ("indeterminate").

  # `<progress>` — `value` and `max` (default max=1). `position`
  # returns `value / max` for a "determinate" progress bar, or -1
  # when no value is set ("indeterminate").
  class HTMLProgressElement < HTMLElement
    # A progress bar is "determinate" iff it has a parseable `value` content
    # attribute; otherwise it is "indeterminate" (position -1). The `value` IDL
    # getter always returns a number: 0 when indeterminate/invalid, else the
    # value clamped to [0, max].
    def value
      raw = @__node__["value"].to_s
      return 0.0 if raw.empty?

      v = Float(raw) rescue 0.0
      v = 0.0 if v < 0
      [v, max].min
    end

    def value=(v)
      set_reflected_string("value", v.to_s)
    end

    def max
      raw = @__node__["max"].to_s
      m = raw.empty? ? 1.0 : (Float(raw) rescue 1.0)
      # A `max` not greater than zero is invalid; the default (1) applies.
      m > 0 ? m : 1.0
    end

    # The `max` IDL attribute is limited to numbers greater than zero: a setter
    # value that isn't is ignored (the content attribute is left unchanged).
    def max=(v)
      f = Float(v) rescue nil
      set_reflected_string("max", v.to_s) if f && f > 0
    end

    # `position` = value/max for a determinate bar; -1 for an indeterminate one
    # (no parseable value content attribute).
    def position
      return -1.0 unless determinate?

      value / max
    end

    def labels
      labels_node_list
    end

    def __js_get__(key)
      case key
      when "value"
        value
      when "max"
        max
      when "position"
        position
      when "labels"
        labels
      else
        super
      end
    end

    def __js_set__(key, v)
      case key
      when "value"
        self.value = v
      when "max"
        self.max = v
      else
        super
      end
    end

    private

    # Determinate iff the `value` content attribute is present and parseable.
    def determinate?
      raw = @__node__["value"].to_s
      return false if raw.empty?

      !!(Float(raw) rescue nil)
    end
  end

  # `<template>` — `content` returns the DocumentFragment that
  # owns the template's children. Reuses the document-level
  # template_content storage so existing template handling stays
  # consistent.

  class HTMLDataListElement < HTMLElement
    # `options` — the <option> descendants, as a live HTMLCollection.
    def options
      el = self
      HTMLCollection.new do
        el.__dommy_backend_node__.css("option").map { |n| el.document.wrap_node(n) }.compact
      end
    end

    def __js_get__(key)
      return options if key == "options"

      super
    end
  end
end
