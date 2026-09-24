# frozen_string_literal: true

module Dommy
  # The `<form>` itself, and the controls that are neither `<input>` nor
  # `<select>`.
  #
  # One of the form-control groups; html_elements/forms.rb lists them.
  # The form and its controls: what a user fills in and what a form submits.
  #
  # One of the HTML element groups; html_elements.rb lists them all.
  # `<form>` — element collection, submit/reset, and a stubbed
  # validation surface.
  class HTMLFormElement < HTMLElement
    include SubmissionUrlAttribute
    reflect_token_list rel_list: { attr: "rel", js: "relList" }
    reflect_setter :action
    def action = submission_url("action")
    reflect_string :name, :enctype, :target, :autocomplete, method_attr: { attr: "method", js: "method" }, accept_charset: "accept-charset"
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

  # `<button>` — type defaults to "submit" per spec.
  class HTMLButtonElement < HTMLElement
    include SubmitButtonActivation
    reflect_string :name, :value, form_enctype: "formenctype", form_method: "formmethod", form_target: "formtarget"
    reflect_boolean :disabled, :autofocus, form_no_validate: "formnovalidate"
    include SubmissionUrlAttribute
    reflect_setter form_action: "formaction"
    def form_action = submission_url("formaction")

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

  # `<textarea>` — multi-line text input.
  class HTMLTextAreaElement < HTMLElement
    include Internal::TextSelection
    reflect_boolean :disabled, :required, read_only: "readonly"
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

    js_accessor :value, :default_value, :rows, :cols, :max_length, :min_length, :selection_start, :selection_end, :selection_direction
    js_readable :text_length, :type, :form, :labels, :validity, :will_validate, :validation_message


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

    js_readable :control, :form
  end

  # `<fieldset>` — disabled-state-propagating wrapper; exposes
  # `elements` collection like form.

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

    js_readable :type, :form, :elements, :validity, :will_validate

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

  # `<output>` — calculation result element.
  class HTMLOutputElement < HTMLElement
    reflect_string :name
    reflect_token_list html_for: { attr: "for", js: "htmlFor" }

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

    js_accessor :value, :max
    js_readable :position, :labels


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
end
