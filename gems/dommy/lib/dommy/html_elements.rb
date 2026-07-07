# frozen_string_literal: true

require "date"

module Dommy
  # Base for specialized HTMLElement subclasses. Inherits reflection
  # helpers from Internal::ReflectedAttributes (also shared with
  # SVGElement).
  class HTMLElement < Element
    include Internal::ReflectedAttributes

    # HTML attribute names are case-insensitive — the browser DOM
    # lowercases everything. Override to make this explicit at the
    # HTMLElement level (Element's default would already pick this up
    # via namespace inspection, but spelling it out shortcuts the
    # namespace check for HTML's hot path).
    def case_sensitive_attribute_names?
      false
    end

    # The `labels` NodeList for a labelable control: every <label> in the
    # document whose labeled `control` resolves to this element — via an explicit
    # `for=` reference OR by wrapping it as the label's first labelable
    # descendant (so nested/ancestor labels count). Shared by button, input,
    # meter, output, progress, select, and textarea. Live, so a retained
    # reference reflects later DOM/type changes (e.g. an input turning `hidden`
    # drops out of its labels). Memoized so it is the [SameObject] across reads.
    def labels_node_list
      el = self
      @__labels_node_list ||= LiveNodeList.new do
        me = el.__dommy_backend_node__
        el.document.query_selector_all("label").select do |label|
          next false unless label.respond_to?(:control)

          c = label.control
          c.respond_to?(:__dommy_backend_node__) && c.__dommy_backend_node__.equal?(me)
        end
      end
    end

    private

    # HTML "rules for parsing integers": optional leading ASCII whitespace, an
    # optional sign, then ASCII digits (trailing junk allowed). Returns the
    # integer, or nil when the value is absent or doesn't begin with a valid
    # integer — callers supply the reflected attribute's default.
    def parse_html_integer(value)
      return nil if value.nil?

      match = value.to_s.sub(/\A[ \t\n\f\r]+/, "").match(/\A[-+]?\d+/)
      match ? match[0].to_i : nil
    end
  end

  # `<a>` — exposes URL-component getters/setters via the `href`
  # attribute, plus reflected `target` / `download` / `rel` / `type`.
  # Follow-the-hyperlink activation behavior shared by <a> and <area>. A
  # non-canceled click on a hyperlink (with an href, no download attribute)
  # navigates to its resolved URL: a same-document fragment change fires
  # hashchange and updates :target; anything else is handed to the navigation
  # delegate (which performs the real navigation, or records it by default).
  module HyperlinkActivation
    def activation_target?
      has_attribute?("href")
    end

    def activation_behavior(_event)
      return unless has_attribute?("href")
      # download turns the click into a save, not a navigation — out of scope.
      return if has_attribute?("download")

      target = anchor_href
      win = @document&.default_view
      return if target.to_s.empty? || win.nil? || win.location.nil?

      # A cross-document link hands off to the delegate without pre-mutating the
      # location; a same-document fragment still updates the hash + :target.
      win.location.__internal_navigate_to__(target, source: :link, sync_cross_doc: false)
    end
  end

  class HTMLAnchorElement < HTMLElement
    include HyperlinkActivation
    reflect_string :target, :download, :rel, :hreflang, :type
    # URL-decomposition helpers. The anchor's `href` is resolved to
    # an absolute URL (inherited from Element#anchor_href); break it
    # into the standard components on demand.
    def hash
      uri_part(:fragment) ? "##{uri_part(:fragment)}" : ""
    end

    def host
      uri.host ? "#{uri.host}#{port_suffix}" : ""
    end

    def hostname
      uri.host || ""
    end

    def pathname
      uri.path || "/"
    end

    def protocol
      uri.scheme ? "#{uri.scheme}:" : ""
    end

    def search
      uri.query ? "?#{uri.query}" : ""
    end

    def port
      uri.port ? uri.port.to_s : ""
    end

    def origin
      uri.scheme && uri.host ? "#{uri.scheme}://#{uri.host}#{port_suffix}" : ""
    end

    # `a.text` is an alias for the element's descendant text content.
    def text
      text_content
    end

    def text=(v)
      self.text_content = v.to_s
    end

    def __js_get__(key)
      case key
      when "hash"
        self.hash
      when "host"
        host
      when "hostname"
        hostname
      when "pathname"
        pathname
      when "protocol"
        protocol
      when "search"
        search
      when "port"
        port
      when "origin"
        origin
      when "text"
        text
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "text"
        self.text = value
      else
        super
      end
    end

    private

    def uri
      require "uri"

      URI(anchor_href)
    rescue URI::InvalidURIError, ArgumentError
      URI("")
    end

    def uri_part(part)
      uri.send(part)
    end

    def port_suffix
      return "" unless uri.port

      default = uri.scheme == "https" ? 443 : 80
      uri.port == default ? "" : ":#{uri.port}"
    end
  end

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

    def elements
      el = self
      @elements ||= HTMLFormControlsCollection.new do
        el.document.query_selector_all(LISTED_CONTROL_SELECTOR).select do |c|
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
      form_id = control.__dommy_backend_node__["form"].to_s
      owner =
        if form_id.empty?
          control.closest("form")
        else
          target = control.document.get_element_by_id(form_id)
          (target && target.tag_name.to_s.casecmp?("form")) ? target : nil
        end
      !owner.nil? && owner.__dommy_backend_node__.equal?(__dommy_backend_node__)
    end

    def length
      elements.size
    end

    # Spec: `submit()` performs form submission directly WITHOUT
    # firing a `submit` event. This is the JS-only entry point —
    # browsers don't run constraint validation either. Dommy has no
    # navigation engine, so this is effectively a no-op (returns nil).
    def submit
      nil
    end

    # Spec: `reset()` does fire a `reset` event; if the event is
    # default-prevented, no reset happens. Dommy has no built-in
    # control re-init logic, so we just dispatch the event.
    def reset
      dispatch_event(Event.new("reset", "bubbles" => true, "cancelable" => true))
    end

    # Spec: `requestSubmit(submitter?)` is the JS counterpart that
    # MIRRORS user-initiated submission — it runs constraint validation
    # and fires a `submit` event. Returns true if not default-prevented.
    # `submitter` (if given) must be a button inside this form.
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

      dispatch_event(Event.new("submit", "bubbles" => true, "cancelable" => true))
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
      named = named_controls[key.to_s]
      return __named_getter_result__(key.to_s, named) if named && !named.empty?

      case key
      when "elements"
        elements
      when "length"
        length
      else
        super
      end
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
    # of each of its listed controls.
    def __js_named_props__
      named_controls.keys
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
  class HTMLInputElement < HTMLElement
    reflect_string :name, :placeholder, :min, :max, :step, :pattern, :autocomplete, default_value: "value"
    reflect_boolean :autofocus, :disabled, :required, :readonly, default_checked: "checked"
    # Own __js_call__ methods, on top of Element's.
    def type
      raw = @__node__["type"].to_s
      raw.empty? ? "text" : raw.downcase
    end

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
      return "on" if raw.to_s.empty? && !@__node__.key?("value") && %w[checkbox radio].include?(type)

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
    end

    # `files` — for `<input type="file">`. Browsers populate this via
    # user interaction; in tests, code uses `__driver_set_files__` to seed it.
    def files
      @__files ||= FileList.new
    end

    # Test-only seam: set the input's file list directly.
    # Accepts an array (wrapped in a FileList) or a FileList itself.
    def __driver_set_files__(files_input)
      @__files = files_input.is_a?(FileList) ? files_input : FileList.new(Array(files_input))
    end

    # Spec: the "value sanitization algorithm" runs lazily on read.
    # type=email/url trim leading/trailing ASCII whitespace; type=number
    # rejects non-finite floats by returning "" (badInput stays true
    # so validity surfaces the original raw value).
    def sanitize_value(raw)
      case type
      when "email"
        if @__node__.key?("multiple")
          raw.to_s.split(",").map(&:strip).join(",")
        else
          raw.to_s.strip
        end

      when "url"
        raw.to_s.strip
      when "number", "range"
        sanitize_number(raw)
      when "color"
        s = raw.to_s.strip.downcase
        s.match?(/\A#[0-9a-f]{6}\z/) ? s : "#000000"
      else
        raw.to_s
      end
    end

    def sanitize_number(raw)
      s = raw.to_s
      Float(s)
      s
    rescue ArgumentError, TypeError
      ""
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
      # is selector-observable via :checked — invalidate computed styles.
      @document&.__internal_bump_style_generation__
    end

    # `indeterminate` is pure property state (no content attribute), default
    # false. Selector-observable via :indeterminate, so bump style generation.
    def indeterminate
      @__indeterminate || false
    end

    def indeterminate=(v)
      @__indeterminate = !!v
      @document&.__internal_bump_style_generation__
    end

    # --- Click activation behavior (checkbox / radio) -------------------

    # HTML pre-click activation: a checkbox toggles; a radio becomes checked
    # (which unchecks its group). Returns the state needed to undo this if the
    # click is canceled, or nil for inputs with no activation behavior.
    def pre_click_activation_state
      # Only a mutable (enabled) checkbox/radio has activation behavior.
      return nil if disabled

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

    # Not canceled: fire `input` then `change` (HTML "input activation
    # behavior"). Both are UA-generated, so trusted and non-cancelable.
    def run_post_click_activation(_state)
      dispatch_event(Event.new("input", "bubbles" => true).__internal_mark_trusted__)
      dispatch_event(Event.new("change", "bubbles" => true).__internal_mark_trusted__)
    end

    # Canceled (default prevented): restore the pre-click checkedness. For a
    # radio, also re-check whichever member was checked before.
    def restore_pre_click_activation(state)
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
      @document&.__internal_bump_style_generation__
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
      form_id = get_attribute("form").to_s
      unless form_id.empty?
        target = @document.get_element_by_id(form_id)
        return (target && target.tag_name.to_s.casecmp?("form")) ? target : nil
      end

      closest("form")
    end

    # Only these input types expose a variable-length text selection; the rest
    # return null for the selection attributes and throw on the setters/methods.
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

    # Input types whose value has a numeric representation (valueAsNumber /
    # stepUp / stepDown apply).
    def numeric_value_type?
      %w[number range date month week time datetime-local].include?(type)
    end

    def range_min
      Float(@__node__["min"].to_s) rescue 0.0
    end

    def range_max
      Float(@__node__["max"].to_s) rescue 100.0
    end

    # A range with no (valid) value defaults to the midpoint of its range, or the
    # minimum when the maximum is below it.
    def default_range_value(lo, hi)
      hi < lo ? lo : lo + (hi - lo) / 2.0
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
      base = before.nan? ? (mn || 0.0) : before
      result = base + count * allowed

      step_base = mn || 0.0
      result = mx - (mx - step_base) % allowed if mx && result > mx
      result = mn + (step_base - mn) % allowed if mn && result < mn

      # Clamping must never move the value against the step direction (e.g. a
      # stepDown on a value already below min must not jump UP to min).
      unless before.nan?
        return if count.positive? && result < before
        return if count.negative? && result > before
      end

      self.value_as_number = result
      nil
    end

    # The scale that turns one declared step into valueAsNumber units (ms for the
    # date/time types, natural units for number/range/month).
    def step_scale_factor
      case type
      when "date" then 86_400_000
      when "week" then 604_800_000
      when "time", "datetime-local" then 1000
      else 1
      end
    end

    # The default allowed step (in the type's own step units) when `step` is
    # absent or invalid: 60 (seconds) for time/datetime-local, 1 otherwise.
    def default_step
      %w[time datetime-local].include?(type) ? 60.0 : 1.0
    end

    # The `min`/`max` boundary as a valueAsNumber, or nil when absent/unparseable.
    def step_boundary(attr)
      raw = @__node__[attr].to_s.strip
      return nil if raw.empty?

      case type
      when "number", "range" then (Float(raw) rescue nil)
      when "date" then nan_to_nil(date_string_to_ms(raw))
      when "time" then nan_to_nil(time_string_to_ms(raw))
      when "datetime-local" then nan_to_nil(datetime_local_string_to_ms(raw))
      when "month" then nan_to_nil(month_string_to_number(raw))
      when "week" then nan_to_nil(week_string_to_ms(raw))
      end
    end

    def nan_to_nil(n)
      n.nan? ? nil : n
    end

    # JS Number-to-string: an integral value drops the trailing ".0".
    def number_to_string(n)
      return "" if n.nan?

      n == n.to_i ? n.to_i.to_s : n.to_s
    end

    # WHATWG "valid floating-point number": no surrounding whitespace (unlike
    # Ruby's Float()), optional sign, digits with optional fraction, optional
    # exponent. Anything else — including " 1 " or "1e" — yields NaN.
    VALID_FLOAT_RE = /\A-?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?\z/

    def parse_valid_float(str)
      s = str.to_s
      VALID_FLOAT_RE.match?(s) ? (Float(s) rescue ::Float::NAN) : ::Float::NAN
    end

    # --- Date/time "convert a string to a number" algorithms (all UTC) --------

    def date_string_to_ms(s)
      m = /\A(\d{4,})-(\d{2})-(\d{2})\z/.match(s.strip)
      return ::Float::NAN unless m

      y, mo, d = m[1].to_i, m[2].to_i, m[3].to_i
      return ::Float::NAN if y < 1 || !::Date.valid_date?(y, mo, d)

      ::Time.utc(y, mo, d).to_i * 1000.0
    end

    def time_string_to_ms(s)
      m = /\A(\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?\z/.match(s.strip)
      return ::Float::NAN unless m

      h, mi, se = m[1].to_i, m[2].to_i, m[3].to_i
      return ::Float::NAN if h > 23 || mi > 59 || se > 59

      frac = m[4] ? m[4].ljust(3, "0").to_i : 0
      ((h * 3600 + mi * 60 + se) * 1000 + frac).to_f
    end

    def datetime_local_string_to_ms(s)
      # The date/time separator may be "T" or a space (the "parse a local date
      # and time string" algorithm accepts both).
      m = /\A(\d{4,})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.(\d{1,3}))?)?\z/.match(s.strip)
      return ::Float::NAN unless m

      y, mo, d, h, mi, se = m[1].to_i, m[2].to_i, m[3].to_i, m[4].to_i, m[5].to_i, m[6].to_i
      return ::Float::NAN if y < 1 || !::Date.valid_date?(y, mo, d) || h > 23 || mi > 59 || se > 59

      frac = m[7] ? m[7].ljust(3, "0").to_i : 0
      (::Time.utc(y, mo, d, h, mi, se).to_i * 1000 + frac).to_f
    end

    def month_string_to_number(s)
      m = /\A(\d{4,})-(\d{2})\z/.match(s.strip)
      return ::Float::NAN unless m

      y, mo = m[1].to_i, m[2].to_i
      return ::Float::NAN if y < 1 || mo < 1 || mo > 12

      ((y - 1970) * 12 + (mo - 1)).to_f
    end

    def week_string_to_ms(s)
      m = /\A(\d{4,})-W(\d{2})\z/.match(s.strip)
      return ::Float::NAN unless m

      y, w = m[1].to_i, m[2].to_i
      return ::Float::NAN if y < 1 || w < 1

      # Date.commercial raises for a week beyond the ISO year's 52/53 weeks.
      d = ::Date.commercial(y, w, 1)
      ::Time.utc(d.year, d.month, d.day).to_i * 1000.0
    rescue ::ArgumentError
      ::Float::NAN
    end

    # --- Inverse: "convert a number to a string" for the date/time types -------

    def utc_time_from_ms(ms)
      ::Time.at(ms / 1000.0).utc
    end

    def ms_to_date_string(ms)
      return "" if ms.nan?

      t = utc_time_from_ms(ms)
      format("%04d-%02d-%02d", t.year, t.month, t.day)
    rescue ::RangeError, ::ArgumentError, ::FloatDomainError
      ""
    end

    def ms_to_time_string(ms)
      return "" if ms.nan?

      v = (ms % 86_400_000).to_i
      h = v / 3_600_000
      mi = (v % 3_600_000) / 60_000
      se = (v % 60_000) / 1000
      frac = v % 1000
      if se.zero? && frac.zero?
        format("%02d:%02d", h, mi)
      elsif frac.zero?
        format("%02d:%02d:%02d", h, mi, se)
      else
        format("%02d:%02d:%02d.%03d", h, mi, se, frac)
      end
    end

    def ms_to_datetime_local_string(ms)
      return "" if ms.nan?

      t = utc_time_from_ms(ms)
      return "" if t.year < 1 || t.year > 9999

      base = format("%04d-%02d-%02dT%02d:%02d", t.year, t.month, t.day, t.hour, t.min)
      frac = (ms % 1000).to_i
      if t.sec.zero? && frac.zero?
        base
      elsif frac.zero?
        base + format(":%02d", t.sec)
      else
        base + format(":%02d.%03d", t.sec, frac)
      end
    rescue ::RangeError, ::ArgumentError, ::FloatDomainError
      ""
    end

    def number_to_month_string(n)
      return "" if n.nan?

      months = n.to_i
      y = 1970 + (months.fdiv(12).floor)
      mo = months % 12
      format("%04d-%02d", y, mo + 1)
    end

    def ms_to_week_string(ms)
      return "" if ms.nan?

      t = utc_time_from_ms(ms)
      d = ::Date.new(t.year, t.month, t.day)
      format("%04d-W%02d", d.cwyear, d.cweek)
    rescue ::RangeError, ::ArgumentError, ::FloatDomainError
      ""
    end

    # `valueAsNumber` — the control's value as a number, per the type's
    # "convert a string to a number" algorithm (NaN when the type has no number
    # representation or the value doesn't parse). number/range are plain floats;
    # range additionally defaults to its midpoint and clamps to [min, max].
    def value_as_number
      case type
      when "number"
        parse_valid_float(value.to_s)
      when "range"
        n = parse_valid_float(value.to_s)
        n = nil if n.nan?
        lo = range_min
        hi = range_max
        n = default_range_value(lo, hi) if n.nil?
        n.clamp(lo, hi)
      when "date"
        date_string_to_ms(value.to_s)
      when "time"
        time_string_to_ms(value.to_s)
      when "datetime-local"
        datetime_local_string_to_ms(value.to_s)
      when "month"
        month_string_to_number(value.to_s)
      when "week"
        week_string_to_ms(value.to_s)
      else
        ::Float::NAN
      end
    end

    def value_as_number=(n)
      f = n.to_f
      case type
      when "number", "range"
        self.value = f.nan? ? "" : number_to_string(f)
      when "date"
        self.value = ms_to_date_string(f)
      when "time"
        self.value = ms_to_time_string(f)
      when "datetime-local"
        self.value = ms_to_datetime_local_string(f)
      when "month"
        self.value = number_to_month_string(f)
      when "week"
        self.value = ms_to_week_string(f)
      else
        raise DOMException::InvalidStateError, "valueAsNumber is not applicable to input type '#{type}'"
      end
    end

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

    # The step base for validation: the min boundary if present, else 0.
    def validation_step_base
      return min_as_number if min_as_number

      # The default step base is 0 for most types, but a `week` control aligns to
      # the Monday of 1970-W01 (the epoch is mid-week), so an unmatched default
      # base would report every whole week as a step mismatch.
      type == "week" ? week_string_to_ms("1970-W01") : 0.0
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

    # Whether this control participates in constraint validation.
    # Disabled / hidden / button-type inputs return false.
    def will_validate
      return false if reflected_boolean("disabled")
      return false if reflected_boolean("readonly")
      return false if %w[hidden button submit reset image].include?(type)
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

    def __js_get__(key)
      case key
      when "type"
        type
      when "value"
        value
      when "checked"
        checked
      when "indeterminate"
        indeterminate
      when "readonly", "readOnly"
        readonly
      when "labels"
        labels
      when "form"
        form
      when "validity"
        validity
      when "willValidate"
        will_validate
      when "validationMessage"
        validation_message
      when "files"
        files
      when "selectionStart"
        selection_start
      when "selectionEnd"
        selection_end
      when "selectionDirection"
        selection_direction
      when "valueAsNumber"
        value_as_number
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "type"
        set_reflected_string("type", value)
      when "value"
        self.value = value
      when "valueAsNumber"
        self.value_as_number = value
      when "selectionStart"
        self.selection_start = value
      when "selectionEnd"
        self.selection_end = value
      when "selectionDirection"
        self.selection_direction = value
      when "checked"
        self.checked = value
      when "indeterminate"
        self.indeterminate = value
      when "readonly", "readOnly"
        self.readonly = value
      else
        super
      end
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
  class HTMLButtonElement < HTMLElement
    reflect_string :name, form_action: "formaction", form_enctype: "formenctype", form_method: "formmethod", form_target: "formtarget"
    reflect_boolean :disabled, :autofocus, form_no_validate: "formnovalidate"
    def type
      raw = @__node__["type"].to_s.downcase
      %w[submit reset button].include?(raw) ? raw : "submit"
    end

    def type=(v)
      set_reflected_string("type", v)
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

    # Buttons don't participate in constraint validation (per spec).
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
  class HTMLImageElement < HTMLElement
    reflect_string :src, :alt, :decoding, :loading, :sizes, :srcset, crossorigin: { js: "crossOrigin" }, referrer_policy: "referrerpolicy"
    def width
      @__node__["width"].to_s.to_i
    end

    def width=(v)
      set_reflected_string("width", v.to_s)
    end

    def height
      @__node__["height"].to_s.to_i
    end

    def height=(v)
      set_reflected_string("height", v.to_s)
    end

    # No real loader → these are constants.
    def natural_width
      0
    end

    def natural_height
      0
    end

    def complete
      true
    end

    def current_src
      src
    end

    def __js_get__(key)
      case key
      when "width"
        width
      when "height"
        height
      when "naturalWidth"
        natural_width
      when "naturalHeight"
        natural_height
      when "complete"
        complete
      when "currentSrc"
        current_src
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "width", "height"
        set_reflected_string(key, value.to_s)
      else
        super
      end
    end
  end

  # `<script>` — `src` / `type` / `async` / `defer` / `text`.
  class HTMLScriptElement < HTMLElement
    reflect_string :src, :type, :integrity, :nonce, referrer_policy: "referrerpolicy"
    reflect_boolean :async, :defer, no_module: "nomodule"
    # `text` is an alias for textContent on <script>.
    def text
      text_content
    end

    def text=(v)
      self.text_content = v
    end

    def __js_get__(key)
      case key
      when "text"
        text
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "text"
        self.text_content = value
      else
        super
      end
    end

    # The classic-script source to execute now that this element is connected,
    # or nil if it must not run: a `src` script (no network here), a non-classic
    # type (module/JSON/etc.), an empty body, or one that already ran. The
    # "already started" flag (set on first call) makes execution happen at most
    # once, even if the node is re-inserted. The host eval is wired by the JS
    # bridge via Document#script_runner.
    # Module scripts are excluded — they need module scope / import resolution
    # the classic eval path can't provide (left to a future module loader).
    CLASSIC_SCRIPT_TYPES = ["", "text/javascript", "application/javascript",
                            "application/ecmascript", "text/ecmascript"].freeze

    # Set the HTML "already started" flag without running anything. The fragment
    # parsing algorithm (innerHTML / insertAdjacentHTML / outerHTML / DOMParser)
    # flags its scripts this way so they never execute on insertion.
    def __internal_mark_script_already_started__
      @__script_started = true
      nil
    end

    def __internal_take_pending_script__
      return nil if @__script_started
      return nil unless src.to_s.empty?
      return nil unless CLASSIC_SCRIPT_TYPES.include?(type.to_s.strip.downcase)

      body = text_content.to_s
      return nil if body.strip.empty?

      @__script_started = true
      body
    end

    # The classic-script `src` to fetch and execute now, or nil if it must not
    # run: an inline script (no src), a non-classic type (module/JSON/etc.), or
    # one that already ran. The external counterpart of
    # #__internal_take_pending_script__ — it sets the same "already started"
    # flag so the host fetches/executes the external body at most once, even if
    # the node is re-inserted. The fetch itself is the host's job (Dommy has no
    # network); this only decides eligibility and returns the URL.
    def __internal_take_pending_src__
      return nil if @__script_started

      s = src.to_s
      return nil if s.empty?
      return nil unless CLASSIC_SCRIPT_TYPES.include?(type.to_s.strip.downcase)

      @__script_started = true
      s
    end

    # A `type="module"` script to evaluate now, or nil if it must not run (a
    # non-module type, an empty inline body, or one that already ran). Returns
    # `[:inline, body]` or `[:external, src]`; the host evaluates it as an ES
    # module (resolving its imports). Sets the same "already started" flag so a
    # module runs at most once.
    def __internal_take_pending_module__
      return nil if @__script_started
      return nil unless type.to_s.strip.downcase == "module"

      s = src.to_s
      if s.empty?
        body = text_content.to_s
        return nil if body.strip.empty?

        @__script_started = true
        [:inline, body]
      else
        @__script_started = true
        [:external, s]
      end
    end
  end

  # `<link>` — primarily for stylesheets, icons, preload, manifests.
  class HTMLLinkElement < HTMLElement
    reflect_string :href, :rel, :type, :media, :sizes, :hreflang, :integrity, as_attr: { attr: "as", js: "as" }, crossorigin: { js: "crossOrigin" }, referrer_policy: "referrerpolicy"
    # `link.sheet` — non-nil only when this link is a stylesheet
    # (`rel` contains "stylesheet"). Dommy fetches nothing itself, so the
    # sheet starts empty; a host environment supplies the CSS via
    # `set_stylesheet_text`. Once filled it participates in the cascade and
    # `insertRule` / `deleteRule` work against it like any CSSOM sheet.
    def sheet
      return nil unless stylesheet_rel?

      @__sheet ||= build_link_sheet
    end

    # Host hook (e.g. dommy-rack resolving `<link href>` from a response):
    # supply the CSS this link points at. Re-seeds the sheet — splitting the
    # text into CSSRules — and invalidates the document's computed styles so
    # the next getComputedStyle / visible? sees the new rules.
    def set_stylesheet_text(css)
      return nil unless stylesheet_rel?

      @__sheet = build_link_sheet(css.to_s)
      doc = owner_document
      doc.__internal_bump_style_generation__ if doc.respond_to?(:__internal_bump_style_generation__)
      @__sheet
    end

    # The sheet the cascade should read, or nil when this link isn't a
    # stylesheet or no one instantiated/filled its sheet yet. (Unlike
    # `sheet`, this never instantiates — an untouched link costs nothing.)
    def __internal_stylesheet_for_cascade__
      @__sheet if @__sheet && stylesheet_rel?
    end

    def __js_get__(key)
      case key
      when "sheet"
        sheet
      when "sizes"
        # `link.sizes` is a DOMTokenList (`img`/`source` `sizes` stay strings).
        reflected_token_list("sizes", "sizes")
      else
        super
      end
    end

    private

    def stylesheet_rel?
      rel.split(/\s+/).any? { |token| token.casecmp("stylesheet").zero? }
    end

    def build_link_sheet(source_text = nil)
      CSSStyleSheet.new(
        owner_node: self,
        href: href,
        media: media,
        title: @__node__["title"].to_s,
        type: (type.empty? ? "text/css" : type),
        source_text: source_text
      )
    end
  end

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

    # A control that is disabled or readonly is barred from constraint
    # validation — none of the "suffering from" flags apply.
    def host_barred?
      return false unless @host

      disabled = host_attr_present?("disabled")
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
        return false if host_barred?

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

      # The pattern must be a valid regex ON ITS OWN — validate it before
      # anchoring, so an unbalanced `a)(b` (which the `(?:…)` wrapper would
      # otherwise balance) is correctly discarded rather than silently matched.
      Regexp.new(pat)
      !Regexp.new("\\A(?:#{pat})\\z").match?(v)
    rescue RegexpError
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

      ratio = (num - @host.validation_step_base) / step
      (ratio - ratio.round).abs > 1e-7
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
      when "color"
        !raw.strip.downcase.match?(/\A#[0-9a-f]{6}\z/)
      else
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

    def selected=(value)
      @selectedness = !!value
      @selectedness_dirty = true
    end

    # Set selectedness WITHOUT marking it dirty (the Option constructor's step).
    def __internal_set_selectedness__(value)
      @selectedness = !!value
    end

    # Whether selectedness was set via the IDL setter (property), as opposed to
    # only the content attribute — a single-select shows the most recently
    # property-selected option in preference to an attribute-selected one.
    def __selectedness_dirty__
      @selectedness_dirty || false
    end

    # Keep the `selected` content attribute and selectedness in sync (while not
    # dirty) by hooking the attribute mutators, the way <details> tracks `open`.
    def set_attribute(name, value)
      result = super
      sync_selectedness_from_attribute if name.to_s.casecmp?("selected")
      result
    end

    def remove_attribute(name)
      result = super
      sync_selectedness_from_attribute if name.to_s.casecmp?("selected")
      result
    end

    def sync_selectedness_from_attribute
      @selectedness = default_selected unless @selectedness_dirty
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

    private

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
      html = "http://www.w3.org/1999/xhtml"
      svg = "http://www.w3.org/2000/svg"
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
  class HTMLOptGroupElement < HTMLElement
    reflect_string :label
    reflect_boolean :disabled
  end

  # `<textarea>` — multi-line text input.
  class HTMLTextAreaElement < HTMLElement
    reflect_string :name, :placeholder, :wrap, :autocomplete
    # Own __js_call__ methods, on top of Element's.
    def value
      @__node__["value"] || text_content
    end

    def value=(v)
      @__node__["value"] = v.to_s
      self.text_content = v.to_s
    end

    def default_value
      text_content
    end

    def default_value=(v)
      self.text_content = v
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

    def parse_non_negative_reflected(attr)
      raw = @__node__[attr]
      return -1 if raw.nil?
      # HTML "rules for parsing non-negative integers": leading ASCII whitespace,
      # then digits; anything else (a sign, letters) is an error → -1.
      m = raw.to_s.match(/\A[\t\n\f\r ]*(\d+)/)
      m ? m[1].to_i : -1
    end

    # WHATWG: assigning a negative value to a non-negative reflected long is an
    # IndexSizeError; otherwise reflect it.
    def set_non_negative_reflected(attr, value)
      n = value.to_i
      raise DOMException::IndexSizeError, "#{attr} must be non-negative" if n.negative?

      set_reflected_string(attr, n.to_s)
    end

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
      !reflected_boolean("disabled") && !reflected_boolean("readonly") && closest("datalist").nil?
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
  class HTMLLabelElement < HTMLElement
    reflect_string html_for: "for"
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
  class HTMLSlotElement < HTMLElement
    reflect_string :name
    # Own __js_call__ methods, on top of Element's.

    # `slot.assignedNodes({ flatten: true|false })` — returns the
    # light DOM children currently composed into this slot. With
    # `flatten: true` and no assigned nodes, falls back to the
    # slot's own children (the default content).
    def assigned_nodes(options = nil)
      flatten = options.is_a?(Hash) ? (options["flatten"] || options[:flatten]) : false
      nodes = matching_light_nodes
      if nodes.empty? && flatten
        @__node__.children.map { |n| @document.wrap_node(n) }.compact
      else
        nodes
      end
    end

    def assigned_elements(options = nil)
      assigned_nodes(options).select { |n| n.is_a?(Element) }
    end

    # `slot.assign(...)` — manual assignment (honored only when the
    # owning shadow uses `slotAssignment: "manual"`). We accept the
    # call and fire `slotchange` in both modes; named mode simply
    # ignores the override.
    def assign(*nodes)
      @__manual_assignment = nodes.flatten.select { |n| n.respond_to?(:__dommy_backend_node__) }
      dispatch_event(Event.new("slotchange", "bubbles" => true))
      nil
    end

    def __js_get__(key)
      case key
      when "assignedNodes"
        assigned_nodes
      when "assignedElements"
        assigned_elements
      else
        super
      end
    end

    js_methods %w[assignedNodes assignedElements assign]
    def __js_call__(method, args)
      case method
      when "assignedNodes"
        assigned_nodes(args[0])
      when "assignedElements"
        assigned_elements(args[0])
      when "assign"
        assign(*args)
      else
        super
      end
    end

    private

    def matching_light_nodes
      sr = @document.__internal_shadow_root_containing__(@__node__)
      return [] unless sr

      host = sr.host
      return [] unless host

      slot_name = name
      # Manual mode honors the explicit list.
      if sr.slot_assignment == "manual" && @__manual_assignment
        return @__manual_assignment
      end

      host
        .__dommy_backend_node__
        .children
        .map do |child|
          wrapped = @document.wrap_node(child)
          next nil unless wrapped

          attr_value = child.element? ? child["slot"].to_s : ""
          if slot_name.empty?
            attr_value.empty? ? wrapped : nil
          else
            (child.element? && attr_value == slot_name) ? wrapped : nil
          end
        end
        .compact
    end
  end

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

    # `options` — all <option> descendants (including those inside
    # <optgroup>). Live HTMLOptionsCollection (HTMLCollection +
    # add/remove/selectedIndex/length= helpers).
    def options
      el = self
      HTMLOptionsCollection.new(self) do
        el.__dommy_backend_node__.css("option").map { |n| el.document.wrap_node(n) }.compact
      end
    end

    # `selectedOptions` — live collection of options with `selected`
    # attribute. When nothing is explicitly selected, browsers fall
    # back to the first option for non-multiple selects.
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

    # The option(s) that display as selected, applying the selectedness rules at
    # read time: a single-select shows the LAST option whose selectedness is
    # true (last-selected wins), or — if none is — its first option ("ask for
    # reset"); a multiple select shows every selected option (or none).
    def __display_selected__
      opts = options.to_a
      chosen = opts.select { |o| o.respond_to?(:selected) && o.selected }
      if multiple
        chosen
      elsif !chosen.empty?
        # Single-select: the most recently property-selected option wins over an
        # attribute-selected one; otherwise the last selected in document order.
        dirty = chosen.select { |o| o.respond_to?(:__selectedness_dirty__) && o.__selectedness_dirty__ }
        [(dirty.empty? ? chosen : dirty).last]
      elsif !opts.empty?
        [opts.first]
      else
        []
      end
    end

    def selected_index
      opts = options.to_a
      sel = __display_selected__.first
      return -1 unless sel

      opts.find_index { |o| o.__dommy_backend_node__.equal?(sel.__dommy_backend_node__) } || -1
    end

    def selected_index=(i)
      options.to_a.each_with_index { |o, idx| o.selected = (idx == i.to_i) }
    end

    # `value` of the select = value of the (displayed) selected option, or "".
    def value
      sel = __display_selected__.first
      sel ? sel.value.to_s : ""
    end

    def value=(new_value)
      opts = options.to_a
      target = opts.find { |o| o.value.to_s == new_value.to_s }
      opts.each { |o| o.selected = false }
      target.selected = true if target
    end

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
      target = options[i.to_i]
      target&.remove
    end

    def labels
      return [] if id.empty?

      @document.query_selector_all("label[for='#{id}']")
    end

    def type
      multiple ? "select-multiple" : "select-one"
    end

    def validity
      @__validity ||= ValidityState.new(self)
    end

    def will_validate
      !reflected_boolean("disabled") && closest("datalist").nil?
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

    def __js_get__(key)
      case key
      when "options"
        options
      when "length"
        length
      when "value"
        value
      when "size"
        size
      when "selectedIndex"
        selected_index
      when "selectedOptions"
        selected_options
      when "form"
        form
      when "labels"
        labels
      when "type"
        type
      when "validity"
        validity
      when "willValidate"
        will_validate
      when "validationMessage"
        validation_message
      else
        # Indexed getter: `select[i]` is the option at index i (WebIDL).
        return item(key) if key.is_a?(Integer)
        return item(key.to_i) if key.is_a?(String) && key.match?(/\A\d+\z/)

        super
      end
    end

    def __js_set__(key, val)
      case key
      when "value"
        self.value = val
      when "selectedIndex"
        self.selected_index = val
      when "length"
        self.length = val
      else
        # Indexed setter: `select[i] = option` delegates to the options
        # collection's WebIDL "set an indexed property" algorithm.
        return options.__set_indexed__(key.to_i, val) if key.is_a?(Integer) || (key.is_a?(String) && key.match?(/\A\d+\z/))

        super
      end
    end

    js_methods %w[item namedItem add checkValidity reportValidity setCustomValidity]
    def __js_call__(method, args)
      case method
      when "item"
        item(args[0])
      when "namedItem"
        named_item(args[0])
      when "add"
        add(args[0], args[1])
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
  class HTMLDialogElement < HTMLElement
    reflect_boolean :open
    # Own __js_call__ methods, on top of Element's.

    def return_value
      @return_value ||= ""
    end

    def return_value=(v)
      @return_value = v.to_s
    end

    def show
      self.open = true
      nil
    end

    # `showModal()` requires the dialog to be connected and not already open;
    # otherwise it throws InvalidStateError. (Dommy has no top layer, so the
    # modal itself is functionally the same as show.)
    def show_modal
      if has_attribute?("open")
        raise DOMException::InvalidStateError, "showModal() called on an open dialog"
      end
      unless is_connected?
        raise DOMException::InvalidStateError, "showModal() called on a dialog not connected to a document"
      end

      self.open = true
      nil
    end

    # `close(returnValue?)`: abort if the dialog isn't open; otherwise clear the
    # open attribute, optionally set returnValue, and QUEUE (async) a trusted,
    # non-bubbling `close` event.
    def close(value = nil)
      return nil unless has_attribute?("open")

      self.open = false
      @return_value = value.to_s unless value.nil?
      fire = proc do
        dispatch_event(Event.new("close", "bubbles" => false, "cancelable" => false).__internal_mark_trusted__)
      end
      scheduler = @document.respond_to?(:default_view) && @document.default_view&.scheduler
      scheduler ? scheduler.set_timeout(fire, 0) : fire.call
      nil
    end

    def __js_get__(key)
      case key
      when "returnValue"
        return_value
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "returnValue"
        self.return_value = value
      else
        super
      end
    end

    js_methods %w[show showModal close]
    def __js_call__(method, args)
      case method
      when "show"
        show
      when "showModal"
        show_modal
      when "close"
        close(args[0])
      else
        super
      end
    end
  end

  # `<details>` — `open` reflected boolean. Whenever the open state changes —
  # via the `open` property, setAttribute/removeAttribute, or toggleAttribute —
  # a non-bubbling `toggle` event fires (per spec). Routing the dispatch through
  # the attribute mutators (not just the property setter) is what makes
  # `details.toggleAttribute("open")` fire toggle, which Stimulus's `:open`
  # action option relies on.
  class HTMLDetailsElement < HTMLElement
    reflect_string :name

    def open
      reflected_boolean("open")
    end

    def open=(v)
      set_reflected_boolean("open", v)
    end

    def set_attribute(name, value)
      result = with_toggle_on_open_change { super }
      # Re-point this element to a new exclusive group: if it is open, close the
      # other open members of the group it just joined.
      enforce_group_exclusivity if name.to_s.casecmp?("name") && open
      result
    end

    def remove_attribute(name)
      with_toggle_on_open_change { super }
    end

    def __js_get__(key)
      key == "open" ? open : super
    end

    def __js_set__(key, value)
      if key == "open"
        self.open = value
      else
        super
      end
    end

    private

    def with_toggle_on_open_change
      was = open
      result = yield
      if open != was
        # Opening a named details closes the other open members of its exclusive
        # group (same `name`, same tree scope) before its own toggle is queued.
        enforce_group_exclusivity if open
        queue_toggle_event(was, open)
      end
      result
    end

    # WHATWG details name-group exclusivity: at most one details per (name, tree)
    # may be open. When this element opens, remove `open` from every other open
    # details in the same tree that shares its non-empty name.
    def enforce_group_exclusivity
      group = @__node__["name"].to_s
      return if group.empty?

      root = get_root_node
      return unless root.respond_to?(:query_selector_all)

      root.query_selector_all("details").each do |other|
        next unless other.respond_to?(:__dommy_backend_node__)
        next if other.__dommy_backend_node__.equal?(__dommy_backend_node__)
        next unless other.__dommy_backend_node__["name"].to_s == group

        other.open = false if other.respond_to?(:open) && other.open
      end
    end

    # WHATWG "queue a details toggle event task": the trusted ToggleEvent fires
    # asynchronously, and rapid changes coalesce into ONE event whose oldState is
    # the state before the first change and newState the state after the last.
    def queue_toggle_event(old_open, new_open)
      if @__toggle_pending
        @__toggle_new = new_open ? "open" : "closed"
        return
      end

      @__toggle_pending = true
      @__toggle_old = old_open ? "open" : "closed"
      @__toggle_new = new_open ? "open" : "closed"
      fire = proc do
        @__toggle_pending = false
        evt = ToggleEvent.new("toggle",
          "oldState" => @__toggle_old, "newState" => @__toggle_new,
          "bubbles" => false, "cancelable" => false)
        dispatch_event(evt.__internal_mark_trusted__)
      end
      scheduler = @document.respond_to?(:default_view) && @document.default_view&.scheduler
      scheduler ? scheduler.set_timeout(fire, 0) : fire.call
    end
  end

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
  class HTMLTemplateElement < HTMLElement
    def content
      @document.template_content_fragment(self)
    end

    def __js_get__(key)
      case key
      when "content"
        content
      else
        super
      end
    end
  end

  # `<td>` / `<th>` — single table cell. `cellIndex` is the
  # position within the parent row's cells collection.
  class HTMLTableCellElement < HTMLElement
    reflect_string :headers, :scope, :abbr
    def cell_index
      row = closest("tr")
      return -1 unless row

      row.cells.find_index { |c| c.__dommy_backend_node__ == @__node__ } || -1
    end

    def col_span
      (@__node__["colspan"] || "1").to_i
    end

    def col_span=(v)
      set_reflected_string("colspan", v.to_s)
    end

    def row_span
      (@__node__["rowspan"] || "1").to_i
    end

    def row_span=(v)
      set_reflected_string("rowspan", v.to_s)
    end

    # `scope` / `abbr` are only meaningful on `<th>`, but the IDL
    # exposes them on the cell element either way.

    def __js_get__(key)
      case key
      when "cellIndex"
        cell_index
      when "colSpan"
        col_span
      when "rowSpan"
        row_span
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "colSpan"
        self.col_span = value
      when "rowSpan"
        self.row_span = value
      else
        super
      end
    end
  end

  # `<tr>` — table row. `cells` are direct `<td>`/`<th>` children.
  # `rowIndex` walks the enclosing table; `sectionRowIndex` walks
  # the enclosing thead/tbody/tfoot.
  class HTMLTableRowElement < HTMLElement
    HTML_NAMESPACE = "http://www.w3.org/1999/xhtml"

    # Own __js_call__ methods, on top of Element's.
    def cells
      el = self
      HTMLCollection.new do
        el.__dommy_backend_node__.element_children
          .select { |n| %w[td th].include?(n.name) && el.__html_ns_node__(n) }
          .map { |n| el.document.wrap_node(n) }.compact
      end
    end

    def row_index
      table = closest("table")
      # Only an HTML <table> exposes a rows collection; a foreign (namespaced)
      # <table> ancestor doesn't make this row a table row.
      return -1 unless table.is_a?(HTMLTableElement)

      table.rows.find_index { |r| r.__dommy_backend_node__ == @__node__ } || -1
    end

    def section_row_index
      parent = @__node__.parent
      return -1 unless parent && parent.element? && __html_ns_node__(parent) &&
                       %w[table thead tbody tfoot].include?(parent.name)

      parent.element_children
        .select { |n| n.name == "tr" && __html_ns_node__(n) }
        .find_index { |n| n == @__node__ } || -1
    end

    # `insertCell(index)` — adds a `<td>` at the given index (defaults to end).
    # index < −1 or > cells.length throws IndexSizeError. Returns the new cell.
    def insert_cell(index = -1)
      list = cells.to_a
      i = index.nil? ? -1 : index.to_i
      raise DOMException::IndexSizeError, "insertCell index #{i} out of range" if i < -1 || i > list.size

      cell = @document.create_element("td")
      if i == -1 || i == list.size
        append_child(cell)
      else
        insert_before(cell, list[i])
      end

      cell
    end

    def delete_cell(index)
      list = cells.to_a
      i = index.to_i
      raise DOMException::IndexSizeError, "deleteCell index #{i} out of range" if i < -1 || i >= list.size

      target = i == -1 ? list.last : list[i]
      target&.remove
      nil
    end

    def __html_ns_node__(node)
      el = @document.wrap_node(node)
      !el.respond_to?(:namespace_uri) || el.namespace_uri == HTML_NAMESPACE
    end

    def __js_get__(key)
      case key
      when "cells"
        cells
      when "rowIndex"
        row_index
      when "sectionRowIndex"
        section_row_index
      else
        super
      end
    end

    js_methods %w[insertCell deleteCell]
    def __js_call__(method, args)
      case method
      when "insertCell"
        insert_cell(args[0] || -1)
      when "deleteCell"
        delete_cell(args[0])
      else
        super
      end
    end
  end

  # `<thead>` / `<tbody>` / `<tfoot>` — share section-level row
  # collection + insertRow / deleteRow.
  class HTMLTableSectionElement < HTMLElement
    # Own __js_call__ methods, on top of Element's.
    HTML_NAMESPACE = "http://www.w3.org/1999/xhtml"

    def rows
      el = self
      HTMLCollection.new do
        el.__dommy_backend_node__.element_children
          .select { |n| n.name == "tr" && el.__html_ns_node__(n) }
          .map { |n| el.document.wrap_node(n) }.compact
      end
    end

    def insert_row(index = -1)
      list = rows.to_a
      i = index.nil? ? -1 : index.to_i
      raise DOMException::IndexSizeError, "insertRow index #{i} out of range" if i < -1 || i > list.size

      tr = @document.create_element("tr")
      if i == -1 || i == list.size
        append_child(tr)
      else
        insert_before(tr, list[i])
      end

      tr
    end

    def delete_row(index)
      list = rows.to_a
      i = index.to_i
      raise DOMException::IndexSizeError, "deleteRow index #{i} out of range" if i < -1 || i >= list.size

      target = i == -1 ? list.last : list[i]
      target&.remove
      nil
    end

    def __html_ns_node__(node)
      el = @document.wrap_node(node)
      !el.respond_to?(:namespace_uri) || el.namespace_uri == HTML_NAMESPACE
    end

    def __js_get__(key)
      key == "rows" ? rows : super
    end

    js_methods %w[insertRow deleteRow]
    def __js_call__(method, args)
      case method
      when "insertRow"
        insert_row(args[0] || -1)
      when "deleteRow"
        delete_row(args[0])
      else
        super
      end
    end
  end

  # `<caption>` — table caption, minimal subclass.
  class HTMLTableCaptionElement < HTMLElement
  end

  # `<table>` — top-level table element. `rows` returns rows from
  # all sections (thead → tbody → tfoot); `tBodies` is a list of
  # tbody elements. `insertRow(-1)` appends to the last tbody (or
  # creates one); `deleteRow` works against the merged `rows` list.
  class HTMLTableElement < HTMLElement
    HTML_NAMESPACE = "http://www.w3.org/1999/xhtml"

    # Own __js_call__ methods, on top of Element's.
    def caption
      first_html_child("caption")
    end

    def caption=(new_caption)
      if !new_caption.nil? && !new_caption.is_a?(HTMLTableCaptionElement)
        raise Bridge::TypeError, "table.caption must be an HTMLTableCaptionElement or null"
      end

      delete_caption
      return if new_caption.nil?

      # Route through the validated insertion so a cycle (the caption already
      # containing this table) raises HierarchyRequestError and a caption from
      # another document is adopted, rather than corrupting the tree.
      insert_before(new_caption, first_child)
    end

    def t_head
      first_html_child("thead")
    end

    def t_foot
      first_html_child("tfoot")
    end

    def t_bodies
      el = self
      HTMLCollection.new do
        el.__dommy_backend_node__.element_children
          .select { |n| n.name == "tbody" && el.__html_namespace_node__(n) }
          .map { |n| el.document.wrap_node(n) }.compact
      end
    end

    def rows
      el = self
      HTMLCollection.new do
        # Per spec: thead rows first, then the tr children of the table and of
        # tbody sections IN TREE ORDER (a direct <tr> and a <tbody>'s rows
        # interleave by document position), then tfoot rows.
        head_rows = []
        body_rows = []
        foot_rows = []
        el.__dommy_backend_node__.element_children.each do |n|
          next unless el.__html_namespace_node__(n)

          case n.name
          when "thead"
            el.__tr_children__(n).each { |c| head_rows << c }
          when "tfoot"
            el.__tr_children__(n).each { |c| foot_rows << c }
          when "tbody"
            el.__tr_children__(n).each { |c| body_rows << c }
          when "tr"
            body_rows << n
          end
        end
        (head_rows + body_rows + foot_rows).map { |n| el.document.wrap_node(n) }.compact
      end
    end

    # The HTML-namespaced <tr> element children of a section node.
    def __tr_children__(section)
      section.element_children.select { |n| n.name == "tr" && __html_namespace_node__(n) }
    end

    # The first HTML-namespaced element child with the given local name (a
    # same-name element in another namespace, e.g. SVG's <caption>, is skipped).
    def first_html_child(local)
      node = @__node__.element_children.find { |n| n.name == local && __html_namespace_node__(n) }
      node && @document.wrap_node(node)
    end

    # Whether a raw backend node is in the HTML namespace.
    def __html_namespace_node__(node)
      el = @document.wrap_node(node)
      !el.respond_to?(:namespace_uri) || el.namespace_uri == HTML_NAMESPACE
    end

    def create_caption
      existing = caption
      return existing if existing

      cap = @document.create_element("caption")
      first = @__node__.children.first
      first ? first.add_previous_sibling(cap.__dommy_backend_node__) : @__node__.add_child(cap.__dommy_backend_node__)
      cap
    end

    def delete_caption
      cap = caption
      cap&.remove
      nil
    end

    def create_t_head
      existing = t_head
      return existing if existing

      head = @document.create_element("thead")
      cap = caption
      if cap
        cap.__dommy_backend_node__.add_next_sibling(head.__dommy_backend_node__)
      else
        first = @__node__.children.first
        first ? first.add_previous_sibling(head.__dommy_backend_node__) : @__node__.add_child(head.__dommy_backend_node__)
      end

      head
    end

    def delete_t_head
      t_head&.remove
      nil
    end

    def create_t_foot
      existing = t_foot
      return existing if existing

      foot = @document.create_element("tfoot")
      @__node__.add_child(foot.__dommy_backend_node__)
      foot
    end

    def delete_t_foot
      t_foot&.remove
      nil
    end

    def create_t_body
      tb = @document.create_element("tbody")
      last_tbody = t_bodies.last
      if last_tbody
        last_tbody.__dommy_backend_node__.add_next_sibling(tb.__dommy_backend_node__)
      else
        @__node__.add_child(tb.__dommy_backend_node__)
      end

      tb
    end

    # `table.insertRow(index)` — inserts a `<tr>` at the merged
    # index. Per spec, if no `<tbody>` exists and the table is
    # empty, the row is inserted directly; otherwise it goes into
    # the last `<tbody>`.
    def insert_row(index = -1)
      list = rows.to_a
      raw = index.to_i
      raise DOMException::IndexSizeError, "row index #{raw} out of range" if raw < -1 || raw > list.size

      idx = raw == -1 ? list.size : raw

      tr = @document.create_element("tr")
      if idx == list.size
        target_section = t_bodies.last || create_t_body
        target_section.append_child(tr)
      else
        anchor = list[idx]
        section = anchor.__dommy_backend_node__.parent
        if section
          anchor.__dommy_backend_node__.add_previous_sibling(tr.__dommy_backend_node__)
          @document.notify_child_list_mutation(target_node: section, added_nodes: [tr.__dommy_backend_node__], removed_nodes: [])
        end
      end

      tr
    end

    def delete_row(index)
      list = rows.to_a
      i = index.to_i
      raise DOMException::IndexSizeError, "deleteRow index #{i} out of range" if i < -1 || i >= list.size

      target = i == -1 ? list.last : list[i]
      target&.remove
      nil
    end

    # `table.tHead = x` / `table.tFoot = x`: x must be a matching section element
    # (or null). It replaces the existing one at the spec position.
    def t_head=(value)
      set_table_section("thead", value)
    end

    def t_foot=(value)
      set_table_section("tfoot", value)
    end

    def set_table_section(local, value)
      if value.nil?
        first_html_child(local)&.remove
        return
      end
      # A non-section value fails the WebIDL type check (TypeError); a section of
      # the wrong local name fails the spec's algorithm (HierarchyRequestError).
      unless value.is_a?(HTMLTableSectionElement)
        raise Bridge::TypeError, "table.#{local} must be an HTMLTableSectionElement or null"
      end
      unless value.tag_name.to_s.casecmp?(local)
        raise DOMException::HierarchyRequestError, "table.#{local} must be a <#{local}> element"
      end

      first_html_child(local)&.remove
      # A validated insertion (cycle → HierarchyRequestError, cross-document →
      # adopt). thead goes just after any caption; tfoot is appended last.
      if local == "thead"
        cap = caption
        insert_before(value, cap ? cap.next_sibling : first_child)
      else
        append_child(value)
      end
      value
    end

    def __js_get__(key)
      case key
      when "caption"
        caption
      when "tHead"
        t_head
      when "tFoot"
        t_foot
      when "tBodies"
        t_bodies
      when "rows"
        rows
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "caption"
        self.caption = value
      when "tHead"
        self.t_head = value
      when "tFoot"
        self.t_foot = value
      else
        super
      end
    end

    js_methods %w[
      insertRow deleteRow createCaption deleteCaption createTHead deleteTHead createTFoot
      deleteTFoot createTBody
    ]
    def __js_call__(method, args)
      case method
      when "insertRow"
        insert_row(args[0] || -1)
      when "deleteRow"
        delete_row(args[0])
        Bridge::UNDEFINED
      when "createCaption"
        create_caption
      when "deleteCaption"
        delete_caption
        Bridge::UNDEFINED
      when "createTHead"
        create_t_head
      when "deleteTHead"
        delete_t_head
        Bridge::UNDEFINED
      when "createTFoot"
        create_t_foot
      when "deleteTFoot"
        delete_t_foot
        Bridge::UNDEFINED
      when "createTBody"
        create_t_body
      else
        super
      end
    end
  end

  # `<audio>` / `<video>` shared base. The actual media engine is
  # absent in Dommy — getters return inert values, `play()` returns
  # a resolved Promise, and `pause()` flips `paused` back to true.
  class HTMLMediaElement < HTMLElement
    reflect_string :src, :preload, crossorigin: { js: "crossOrigin" }
    reflect_boolean :autoplay, :controls, loop_: { attr: "loop", js: "loop" }, default_muted: "muted"
    # Own __js_call__ methods, on top of Element's.
    NETWORK_EMPTY = 0
    NETWORK_IDLE = 1
    NETWORK_LOADING = 2
    NETWORK_NO_SOURCE = 3

    HAVE_NOTHING = 0
    HAVE_METADATA = 1
    HAVE_CURRENT_DATA = 2
    HAVE_FUTURE_DATA = 3
    HAVE_ENOUGH_DATA = 4

    def current_src
      src
    end

    def muted
      @__muted == true || reflected_boolean("muted")
    end

    def muted=(v)
      @__muted = !!v
    end

    def paused
      @__paused.nil? ? true : @__paused
    end

    def ended
      false
    end

    def seeking
      false
    end

    def volume
      @__volume.nil? ? 1.0 : @__volume
    end

    def volume=(v)
      @__volume = v.to_f
    end

    def playback_rate
      @__rate.nil? ? 1.0 : @__rate
    end

    def playback_rate=(v)
      @__rate = v.to_f
    end

    def default_playback_rate
      @__default_rate.nil? ? 1.0 : @__default_rate
    end

    def default_playback_rate=(v)
      @__default_rate = v.to_f
    end

    def current_time
      @__current_time.to_f
    end

    def current_time=(v)
      @__current_time = v.to_f
    end

    def duration
      Float::NAN
    end

    def network_state
      NETWORK_EMPTY
    end

    def ready_state
      HAVE_NOTHING
    end

    def play
      @__paused = false
      promise = PromiseValue.new(@document.default_view)
      promise.fulfill(nil)
      promise
    end

    def pause
      @__paused = true
      nil
    end

    def load
      nil
    end

    def can_play_type(_type)
      # spec: "" | "maybe" | "probably". We don't decode → "".
      ""
    end

    def __js_get__(key)
      case key
      when "currentSrc"
        current_src
      when "muted"
        muted
      when "paused"
        paused
      when "ended"
        ended
      when "seeking"
        seeking
      when "volume"
        volume
      when "playbackRate"
        playback_rate
      when "defaultPlaybackRate"
        default_playback_rate
      when "currentTime"
        current_time
      when "duration"
        duration
      when "networkState"
        network_state
      when "readyState"
        ready_state
      when "NETWORK_EMPTY"
        NETWORK_EMPTY
      when "NETWORK_IDLE"
        NETWORK_IDLE
      when "NETWORK_LOADING"
        NETWORK_LOADING
      when "NETWORK_NO_SOURCE"
        NETWORK_NO_SOURCE
      when "HAVE_NOTHING"
        HAVE_NOTHING
      when "HAVE_METADATA"
        HAVE_METADATA
      when "HAVE_CURRENT_DATA"
        HAVE_CURRENT_DATA
      when "HAVE_FUTURE_DATA"
        HAVE_FUTURE_DATA
      when "HAVE_ENOUGH_DATA"
        HAVE_ENOUGH_DATA
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "muted"
        self.muted = value
      when "volume"
        self.volume = value
      when "playbackRate"
        self.playback_rate = value
      when "defaultPlaybackRate"
        self.default_playback_rate = value
      when "currentTime"
        self.current_time = value
      else
        super
      end
    end

    js_methods %w[play pause load canPlayType]
    def __js_call__(method, args)
      case method
      when "play"
        play
      when "pause"
        pause
      when "load"
        load
      when "canPlayType"
        can_play_type(args[0])
      else
        super
      end
    end
  end

  class HTMLAudioElement < HTMLMediaElement
  end

  class HTMLVideoElement < HTMLMediaElement
    reflect_string :poster
    reflect_boolean plays_inline: "playsinline"
    def width
      @__node__["width"].to_s.to_i
    end

    def width=(v)
      set_reflected_string("width", v.to_s)
    end

    def height
      @__node__["height"].to_s.to_i
    end

    def height=(v)
      set_reflected_string("height", v.to_s)
    end

    def video_width
      width
    end

    def video_height
      height
    end

    def __js_get__(key)
      case key
      when "width"
        width
      when "height"
        height
      when "videoWidth"
        video_width
      when "videoHeight"
        video_height
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "width"
        self.width = value
      when "height"
        self.height = value
      else
        super
      end
    end
  end

  class HTMLSourceElement < HTMLElement
    reflect_string :src, :type, :media, :srcset, :sizes
    def width
      @__node__["width"].to_s.to_i
    end

    def width=(v)
      set_reflected_string("width", v.to_s)
    end

    def height
      @__node__["height"].to_s.to_i
    end

    def height=(v)
      set_reflected_string("height", v.to_s)
    end

    def __js_get__(key)
      case key
      when "width"
        width
      when "height"
        height
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "width"
        self.width = value
      when "height"
        self.height = value
      else
        super
      end
    end
  end

  class HTMLTrackElement < HTMLElement
    reflect_string :kind, :src, :srclang, :label
    reflect_boolean default_: { attr: "default", js: "default" }
    NONE = 0
    LOADING = 1
    LOADED = 2
    ERROR = 3

    def ready_state
      NONE
    end

    def __js_get__(key)
      case key
      when "readyState"
        ready_state
      else
        super
      end
    end
  end

  class HTMLIFrameElement < HTMLElement
    reflect_string :src, :srcdoc, :name, :sandbox, :allow, :loading, referrer_policy: "referrerpolicy"
    reflect_boolean allow_fullscreen: "allowfullscreen"
    def width
      @__node__["width"].to_s
    end

    def width=(v)
      set_reflected_string("width", v.to_s)
    end

    def height
      @__node__["height"].to_s
    end

    def height=(v)
      set_reflected_string("height", v.to_s)
    end

    # Dommy doesn't navigate iframes itself, but an integration/test layer can
    # populate the nested browsing context's document (e.g. parsing the `src`
    # resource) via `__internal_set_content_document__`.
    def content_document
      @content_document
    end

    def __internal_set_content_document__(doc)
      @content_document = doc
      # Back-link the nested window to its hosting frame, so getComputedStyle can
      # detect content inside a non-rendered (display:none / disconnected) frame.
      view = doc.respond_to?(:default_view) ? doc.default_view : nil
      view.frame_element = self if view.respond_to?(:frame_element=)
    end

    def content_window
      @content_document&.default_view
    end

    def __js_get__(key)
      case key
      when "width"
        width
      when "height"
        height
      when "contentDocument"
        content_document
      when "contentWindow"
        content_window
      when "sandbox"
        # JS-side `iframe.sandbox` is a DOMTokenList (the Ruby `#sandbox` string
        # accessor from reflect_string is kept for internal use). Non-iframe
        # frame elements get undefined via the element/namespace check.
        reflected_token_list("sandbox", "sandbox")
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "width"
        self.width = value
      when "height"
        self.height = value
      else
        super
      end
    end
  end

  class HTMLPictureElement < HTMLElement
  end

  class HTMLOListElement < HTMLElement
    reflect_string :type
    reflect_boolean :reversed
    # `start` reflects the content attribute as a long with default 1.
    def start
      parse_html_integer(@__node__["start"]) || 1
    end

    def start=(v)
      set_reflected_string("start", v.to_s)
    end

    def __js_get__(key)
      case key
      when "start"
        start
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "start"
        self.start = value
      else
        super
      end
    end
  end

  class HTMLUListElement < HTMLElement
  end

  class HTMLLIElement < HTMLElement
    # `value` reflects the content attribute as a long with default 0.
    def value
      parse_html_integer(@__node__["value"]) || 0
    end

    def value=(v)
      set_reflected_string("value", v.to_s)
    end

    def __js_get__(key)
      key == "value" ? value : super
    end

    def __js_set__(key, value)
      key == "value" ? (self.value = value) : super
    end
  end

  class HTMLTimeElement < HTMLElement
    reflect_string date_time: "datetime"
  end

  class HTMLDataElement < HTMLElement
    reflect_string :value
  end

  # Element interfaces that are otherwise plain HTMLElement subclasses — their
  # own IDL adds little beyond the base, but they must be distinct types so
  # `createElement("col") instanceof HTMLTableColElement` (and cloneNode
  # identity) holds. `col`/`colgroup` share HTMLTableColElement per spec.
  class HTMLTableColElement < HTMLElement; end
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
  class HTMLDirectoryElement < HTMLElement; end
  class HTMLDListElement < HTMLElement; end
  class HTMLFontElement < HTMLElement
    reflect_string :color, :face, :size
  end
  class HTMLFrameElement < HTMLElement; end
  class HTMLFrameSetElement < HTMLElement; end
  class HTMLParamElement < HTMLElement
    reflect_string :name, :value
  end

  class HTMLAreaElement < HTMLElement
    include HyperlinkActivation
    reflect_string :alt, :coords, :shape, :href, :target, :rel
  end

  class HTMLMapElement < HTMLElement
    reflect_string :name
    def areas
      HTMLCollection.new do
        @__node__.css("area").map { |n| @document.wrap_node(n) }.compact
      end
    end

    def __js_get__(key)
      case key
      when "areas"
        areas
      else
        super
      end
    end

    def __js_set__(key, value)
      key == "name" ? (self.name = value) : super
    end
  end

  class HTMLObjectElement < HTMLElement
    reflect_string :data, :type, :name, use_map: "usemap"
    def width
      @__node__["width"].to_s
    end

    def width=(v)
      set_reflected_string("width", v.to_s)
    end

    def height
      @__node__["height"].to_s
    end

    def height=(v)
      set_reflected_string("height", v.to_s)
    end

    def content_document
      nil
    end

    def content_window
      nil
    end

    def __js_get__(key)
      case key
      when "width"
        width
      when "height"
        height
      when "contentDocument"
        content_document
      when "contentWindow"
        content_window
      when "sandbox"
        # JS-side `iframe.sandbox` is a DOMTokenList (the Ruby `#sandbox` string
        # accessor from reflect_string is kept for internal use). Non-iframe
        # frame elements get undefined via the element/namespace check.
        reflected_token_list("sandbox", "sandbox")
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "width"
        self.width = value
      when "height"
        self.height = value
      else
        super
      end
    end
  end

  class HTMLEmbedElement < HTMLElement
    reflect_string :src, :type
    def width
      @__node__["width"].to_s
    end

    def width=(v)
      set_reflected_string("width", v.to_s)
    end

    def height
      @__node__["height"].to_s
    end

    def height=(v)
      set_reflected_string("height", v.to_s)
    end

    def __js_get__(key)
      case key
      when "width"
        width
      when "height"
        height
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "width"
        self.width = value
      when "height"
        self.height = value
      else
        super
      end
    end
  end

  class HTMLBaseElement < HTMLElement
    reflect_string :href, :target
  end

  class HTMLMetaElement < HTMLElement
    reflect_string :name, :content, :charset, http_equiv: "http-equiv"
  end

  class HTMLStyleElement < HTMLElement
    reflect_string :type, :media
    def disabled
      @__disabled == true
    end

    def disabled=(v)
      @__disabled = !!v
    end

    # `style.sheet` — always non-nil for `<style>`. Memoized per text
    # content (CSSOM: repeated reads return the same object), seeded
    # with the element's CSS text so insertRule/deleteRule order against
    # it. Rewriting the element's text discards the sheet and any rules
    # inserted via CSSOM — browsers re-parse into a fresh sheet too.
    def sheet
      text = text_content.to_s
      return @__sheet if @__sheet && @__sheet_text == text

      @__sheet_text = text
      @__sheet = CSSStyleSheet.new(
        owner_node: self,
        media: media,
        title: @__node__["title"].to_s,
        type: (type.empty? ? "text/css" : type),
        source_text: text
      )
    end

    # The memoized sheet, or nil when none was created yet or the
    # element's text changed since (stale sheet). Lets the cascade read
    # CSSOM state only for sheets someone actually touched, without
    # instantiating sheet objects for every `<style>` in the document.
    def __internal_instantiated_sheet__
      @__sheet if @__sheet && @__sheet_text == text_content.to_s
    end

    def __js_get__(key)
      case key
      when "disabled"
        disabled
      when "sheet"
        sheet
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "disabled"
        self.disabled = value
      else
        super
      end
    end
  end

  class HTMLTitleElement < HTMLElement
    def text
      text_content
    end

    def text=(v)
      self.text_content = v.to_s
    end

    def __js_get__(key)
      key == "text" ? text : super
    end

    def __js_set__(key, value)
      key == "text" ? (self.text = value) : super
    end
  end

  class HTMLQuoteElement < HTMLElement
    reflect_string :cite
  end

  class HTMLModElement < HTMLElement
    reflect_string :cite, date_time: "datetime"
  end

  # Identity-only subclasses — useful for `instanceof` / `is_a?` checks
  # in consumer code, even though they don't add reflected IDL attrs
  # beyond what HTMLElement already exposes.
  class HTMLDivElement < HTMLElement
  end

  class HTMLSpanElement < HTMLElement
  end

  class HTMLParagraphElement < HTMLElement
  end

  class HTMLHeadingElement < HTMLElement
  end

  class HTMLBRElement < HTMLElement
  end

  class HTMLHRElement < HTMLElement
  end

  class HTMLPreElement < HTMLElement
  end

  class HTMLBodyElement < HTMLElement
  end

  class HTMLHeadElement < HTMLElement
  end

  class HTMLHtmlElement < HTMLElement
  end
end

# HTMLCanvasElement is a HTMLElement subclass kept in its own file (the canvas
# 2D-context stub is sizeable); required here so the element map below resolves
# the constant. Its runtime-only references (Blob, …) load with the rest.
require_relative "html_canvas_element"

module Dommy
  # Look up the subclass for a given HTML tag. Document#wrap_node
  # consults this map; defaults to plain Element.
  HTML_ELEMENT_CLASSES = {
    "a" => HTMLAnchorElement,
    "form" => HTMLFormElement,
    "input" => HTMLInputElement,
    "button" => HTMLButtonElement,
    "img" => HTMLImageElement,
    "canvas" => HTMLCanvasElement,
    "script" => HTMLScriptElement,
    "link" => HTMLLinkElement,
    "select" => HTMLSelectElement,
    "option" => HTMLOptionElement,
    "optgroup" => HTMLOptGroupElement,
    "textarea" => HTMLTextAreaElement,
    "label" => HTMLLabelElement,
    "fieldset" => HTMLFieldSetElement,
    "output" => HTMLOutputElement,
    "legend" => HTMLLegendElement,
    "slot" => HTMLSlotElement,
    "table" => HTMLTableElement,
    "thead" => HTMLTableSectionElement,
    "tbody" => HTMLTableSectionElement,
    "tfoot" => HTMLTableSectionElement,
    "tr" => HTMLTableRowElement,
    "td" => HTMLTableCellElement,
    "th" => HTMLTableCellElement,
    "caption" => HTMLTableCaptionElement,
    "dialog" => HTMLDialogElement,
    "details" => HTMLDetailsElement,
    "meter" => HTMLMeterElement,
    "progress" => HTMLProgressElement,
    "template" => HTMLTemplateElement,
    "audio" => HTMLAudioElement,
    "video" => HTMLVideoElement,
    "source" => HTMLSourceElement,
    "track" => HTMLTrackElement,
    "iframe" => HTMLIFrameElement,
    "picture" => HTMLPictureElement,
    "ol" => HTMLOListElement,
    "ul" => HTMLUListElement,
    "li" => HTMLLIElement,
    "time" => HTMLTimeElement,
    "data" => HTMLDataElement,
    "area" => HTMLAreaElement,
    "map" => HTMLMapElement,
    "object" => HTMLObjectElement,
    "embed" => HTMLEmbedElement,
    "base" => HTMLBaseElement,
    "meta" => HTMLMetaElement,
    "style" => HTMLStyleElement,
    "title" => HTMLTitleElement,
    "q" => HTMLQuoteElement,
    "blockquote" => HTMLQuoteElement,
    "ins" => HTMLModElement,
    "del" => HTMLModElement,
    "div" => HTMLDivElement,
    "span" => HTMLSpanElement,
    "p" => HTMLParagraphElement,
    "h1" => HTMLHeadingElement,
    "h2" => HTMLHeadingElement,
    "h3" => HTMLHeadingElement,
    "h4" => HTMLHeadingElement,
    "h5" => HTMLHeadingElement,
    "h6" => HTMLHeadingElement,
    "br" => HTMLBRElement,
    "hr" => HTMLHRElement,
    "pre" => HTMLPreElement,
    "body" => HTMLBodyElement,
    "head" => HTMLHeadElement,
    "html" => HTMLHtmlElement,
    "col" => HTMLTableColElement,
    "colgroup" => HTMLTableColElement,
    "datalist" => HTMLDataListElement,
    "dir" => HTMLDirectoryElement,
    "dl" => HTMLDListElement,
    "font" => HTMLFontElement,
    "frame" => HTMLFrameElement,
    "frameset" => HTMLFrameSetElement,
    "param" => HTMLParamElement
  }.freeze

  SVG_NAMESPACE_URI = "http://www.w3.org/2000/svg"
  HTML_NAMESPACE_URI = "http://www.w3.org/1999/xhtml"

  # The interface for an HTML-namespace element whose local name maps to no
  # specialized interface (e.g. createElementNS with an upper-case or otherwise
  # unrecognized name). Still an HTMLElement, so `instanceof HTMLElement` holds.
  class HTMLUnknownElement < HTMLElement
  end

  # Map a (local name, namespace) pair to its DOM interface class. HTML-namespace
  # names match case-SENSITIVELY (createElement lower-cases first, but
  # createElementNS preserves case, so "SPAN" is unknown); any namespace other
  # than HTML/SVG — including the null namespace — gets the generic Element.
  def self.element_class_for(tag_name, namespace_uri = nil)
    name = tag_name.to_s
    case namespace_uri
    when SVG_NAMESPACE_URI
      SVG_ELEMENT_CLASSES[name.downcase] || SVGElement
    when HTML_NAMESPACE_URI
      HTML_ELEMENT_CLASSES[name] || HTMLUnknownElement
    else
      Element
    end
  end
end
