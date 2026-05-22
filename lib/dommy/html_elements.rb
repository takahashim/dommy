# frozen_string_literal: true

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
  end

  # `<a>` — exposes URL-component getters/setters via the `href`
  # attribute, plus reflected `target` / `download` / `rel` / `type`.
  class HTMLAnchorElement < HTMLElement
    def target
      reflected_string("target")
    end

    def target=(v)
      set_reflected_string("target", v)
    end

    def download
      reflected_string("download")
    end

    def download=(v)
      set_reflected_string("download", v)
    end

    def rel
      reflected_string("rel")
    end

    def rel=(v)
      set_reflected_string("rel", v)
    end

    def hreflang
      reflected_string("hreflang")
    end

    def type
      reflected_string("type")
    end

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

    def __js_get__(key)
      case key
      when "target"
        target
      when "download"
        download
      when "rel"
        rel
      when "hreflang"
        hreflang
      when "type"
        type
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
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "target", "download", "rel", "hreflang"
        set_reflected_string(key, value)
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
    def name
      reflected_string("name")
    end

    def name=(v)
      set_reflected_string("name", v)
    end

    def action
      reflected_string("action")
    end

    def action=(v)
      set_reflected_string("action", v)
    end

    def method_attr
      reflected_string("method")
    end

    def method_attr=(v)
      set_reflected_string("method", v)
    end

    def enctype
      reflected_string("enctype")
    end

    def target
      reflected_string("target")
    end

    def autocomplete
      reflected_string("autocomplete")
    end

    def accept_charset
      reflected_string("accept-charset")
    end

    def no_validate
      reflected_boolean("novalidate")
    end

    def no_validate=(v)
      set_reflected_boolean("novalidate", v)
    end

    # `form.elements` — listed elements inside the form (excludes
    # nested forms per spec; we approximate by walking
    # input/select/textarea/button/output/fieldset). Returned as a
    # live HTMLCollection so listening to `submit`/`reset` and
    # adding fields between accesses works as expected.
    def elements
      el = self
      HTMLCollection.new do
        el
          .__node__
          .css("input, select, textarea, button, output, fieldset")
          .map do |n|
            el.document.wrap_node(n)
          end
          .compact
      end
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
        unless submitter.respond_to?(:__node__) && submitter.__node__.ancestors.include?(@__node__)
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
      case key
      when "elements"
        elements
      when "length"
        length
      when "name"
        name
      when "action"
        action
      when "method"
        method_attr
      when "enctype"
        enctype
      when "target"
        target
      when "autocomplete"
        autocomplete
      when "acceptCharset"
        accept_charset
      when "noValidate"
        no_validate
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "name"
        set_reflected_string("name", value)
      when "action"
        set_reflected_string("action", value)
      when "method"
        set_reflected_string("method", value)
      when "enctype"
        set_reflected_string("enctype", value)
      when "target"
        set_reflected_string("target", value)
      when "noValidate"
        set_reflected_boolean("novalidate", value)
      else
        super
      end
    end

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
    def type
      raw = @__node__["type"].to_s
      raw.empty? ? "text" : raw.downcase
    end

    def type=(v)
      set_reflected_string("type", v)
    end

    def name
      reflected_string("name")
    end

    def name=(v)
      set_reflected_string("name", v)
    end

    def placeholder
      reflected_string("placeholder")
    end

    def placeholder=(v)
      set_reflected_string("placeholder", v)
    end

    def min
      reflected_string("min")
    end

    def max
      reflected_string("max")
    end

    def step
      reflected_string("step")
    end

    def pattern
      reflected_string("pattern")
    end

    def autocomplete
      reflected_string("autocomplete")
    end

    def autofocus
      reflected_boolean("autofocus")
    end

    def autofocus=(v)
      set_reflected_boolean("autofocus", v)
    end

    def default_value
      reflected_string("value")
    end

    def default_checked
      reflected_boolean("checked")
    end

    # Runtime value/checked. Dommy has no UI, so the runtime state is
    # initialized from the attribute on first access and tracked
    # separately thereafter — matching browser semantics where the
    # `value` IDL attribute can drift from the `value` content attr.
    def value
      sanitize_value(@__value.nil? ? reflected_string("value") : @__value)
    end

    def value=(v)
      raw = v.to_s
      @__raw_value = raw
      @__value = raw
    end

    # `files` — for `<input type="file">`. Browsers populate this via
    # user interaction; in tests, code uses `__set_files__` to seed it.
    def files
      @__files ||= FileList.new
    end

    # Test-only seam: set the input's file list directly.
    # Accepts an array (wrapped in a FileList) or a FileList itself.
    def __set_files__(files_input)
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
    end

    def disabled
      reflected_boolean("disabled")
    end

    def disabled=(v)
      set_reflected_boolean("disabled", v)
    end

    def required
      reflected_boolean("required")
    end

    def required=(v)
      set_reflected_boolean("required", v)
    end

    def readonly
      reflected_boolean("readonly")
    end

    def readonly=(v)
      set_reflected_boolean("readonly", v)
    end

    def labels
      return [] if id.empty?

      @document.query_selector_all("label[for='#{id}']")
    end

    # Closest enclosing form (or nil if detached / not in a form).
    def form
      closest("form")
    end

    # No real text selection; method stubs let callers proceed.
    def select
      nil
    end

    def set_selection_range(_start, _end, _direction = nil)
      nil
    end

    def set_range_text(_replacement, *_)
      nil
    end

    def step_up(_n = 1)
      nil
    end

    def step_down(_n = 1)
      nil
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
      when "name"
        name
      when "placeholder"
        placeholder
      when "min"
        min
      when "max"
        max
      when "step"
        step
      when "pattern"
        pattern
      when "autocomplete"
        autocomplete
      when "autofocus"
        autofocus
      when "defaultValue"
        default_value
      when "defaultChecked"
        default_checked
      when "value"
        value
      when "checked"
        checked
      when "disabled"
        disabled
      when "required"
        required
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
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "type"
        set_reflected_string("type", value)
      when "name"
        set_reflected_string("name", value)
      when "placeholder"
        set_reflected_string("placeholder", value)
      when "min", "max", "step", "pattern", "autocomplete"
        set_reflected_string(key, value)
      when "autofocus"
        set_reflected_boolean("autofocus", value)
      when "value"
        self.value = value
      when "checked"
        self.checked = value
      when "disabled"
        self.disabled = value
      when "required"
        self.required = value
      when "readonly", "readOnly"
        self.readonly = value
      else
        super
      end
    end

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
    def type
      raw = @__node__["type"].to_s.downcase
      %w[submit reset button].include?(raw) ? raw : "submit"
    end

    def type=(v)
      set_reflected_string("type", v)
    end

    def name
      reflected_string("name")
    end

    def name=(v)
      set_reflected_string("name", v)
    end

    def form_action
      reflected_string("formaction")
    end

    def form_enctype
      reflected_string("formenctype")
    end

    def form_method
      reflected_string("formmethod")
    end

    def form_target
      reflected_string("formtarget")
    end

    def form_no_validate
      reflected_boolean("formnovalidate")
    end

    def form_no_validate=(v)
      set_reflected_boolean("formnovalidate", v)
    end

    def form
      closest("form")
    end

    def labels
      return [] if id.empty?

      @document.query_selector_all("label[for='#{id}']")
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
      when "name"
        name
      when "formAction"
        form_action
      when "formEnctype"
        form_enctype
      when "formMethod"
        form_method
      when "formTarget"
        form_target
      when "formNoValidate"
        form_no_validate
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
      when "name"
        set_reflected_string("name", value)
      when "formAction"
        set_reflected_string("formaction", value)
      when "formEnctype"
        set_reflected_string("formenctype", value)
      when "formMethod"
        set_reflected_string("formmethod", value)
      when "formTarget"
        set_reflected_string("formtarget", value)
      when "formNoValidate"
        set_reflected_boolean("formnovalidate", value)
      else
        super
      end
    end
  end

  # `<img>` — reflected URL/dimension attributes. Dommy has no real
  # image loading, so `complete`/`naturalWidth`/`naturalHeight` are
  # static (complete=true, dimensions=0).
  class HTMLImageElement < HTMLElement
    def src
      reflected_string("src")
    end

    def src=(v)
      set_reflected_string("src", v)
    end

    def alt
      reflected_string("alt")
    end

    def alt=(v)
      set_reflected_string("alt", v)
    end

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

    def crossorigin
      reflected_string("crossorigin")
    end

    def decoding
      reflected_string("decoding")
    end

    def loading
      reflected_string("loading")
    end

    def referrer_policy
      reflected_string("referrerpolicy")
    end

    def sizes
      reflected_string("sizes")
    end

    def srcset
      reflected_string("srcset")
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
      when "src"
        src
      when "alt"
        alt
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
      when "crossOrigin"
        crossorigin
      when "decoding"
        decoding
      when "loading"
        loading
      when "referrerPolicy"
        referrer_policy
      when "sizes"
        sizes
      when "srcset"
        srcset
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "src", "alt", "decoding", "loading", "sizes", "srcset"
        set_reflected_string(key, value)
      when "width", "height"
        set_reflected_string(key, value.to_s)
      when "crossOrigin"
        set_reflected_string("crossorigin", value)
      when "referrerPolicy"
        set_reflected_string("referrerpolicy", value)
      else
        super
      end
    end
  end

  # `<script>` — `src` / `type` / `async` / `defer` / `text`.
  class HTMLScriptElement < HTMLElement
    def src
      reflected_string("src")
    end

    def src=(v)
      set_reflected_string("src", v)
    end

    def type
      reflected_string("type")
    end

    def type=(v)
      set_reflected_string("type", v)
    end

    def integrity
      reflected_string("integrity")
    end

    def nonce
      reflected_string("nonce")
    end

    def referrer_policy
      reflected_string("referrerpolicy")
    end

    def async
      reflected_boolean("async")
    end

    def async=(v)
      set_reflected_boolean("async", v)
    end

    def defer
      reflected_boolean("defer")
    end

    def defer=(v)
      set_reflected_boolean("defer", v)
    end

    def no_module
      reflected_boolean("nomodule")
    end

    def no_module=(v)
      set_reflected_boolean("nomodule", v)
    end

    # `text` is an alias for textContent on <script>.
    def text
      text_content
    end

    def text=(v)
      self.text_content = v
    end

    def __js_get__(key)
      case key
      when "src"
        src
      when "type"
        type
      when "async"
        async
      when "defer"
        defer
      when "noModule"
        no_module
      when "integrity"
        integrity
      when "nonce"
        nonce
      when "referrerPolicy"
        referrer_policy
      when "text"
        text
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "src", "type", "integrity", "nonce"
        set_reflected_string(key, value)
      when "async"
        set_reflected_boolean("async", value)
      when "defer"
        set_reflected_boolean("defer", value)
      when "noModule"
        set_reflected_boolean("nomodule", value)
      when "referrerPolicy"
        set_reflected_string("referrerpolicy", value)
      when "text"
        self.text_content = value
      else
        super
      end
    end
  end

  # `<link>` — primarily for stylesheets, icons, preload, manifests.
  class HTMLLinkElement < HTMLElement
    def href
      reflected_string("href")
    end

    def href=(v)
      set_reflected_string("href", v)
    end

    def rel
      reflected_string("rel")
    end

    def rel=(v)
      set_reflected_string("rel", v)
    end

    def type
      reflected_string("type")
    end

    def type=(v)
      set_reflected_string("type", v)
    end

    def media
      reflected_string("media")
    end

    def sizes
      reflected_string("sizes")
    end

    def hreflang
      reflected_string("hreflang")
    end

    def as_attr
      reflected_string("as")
    end

    def crossorigin
      reflected_string("crossorigin")
    end

    def integrity
      reflected_string("integrity")
    end

    def referrer_policy
      reflected_string("referrerpolicy")
    end

    # `link.sheet` — non-nil only when this link is a stylesheet
    # (`rel` contains "stylesheet"). The sheet itself is a stub:
    # Dommy doesn't fetch or parse CSS, but consumers can still
    # `insertRule` / `deleteRule` against the in-memory sheet.
    def sheet
      return nil unless rel.split(/\s+/).any? { |t| t.casecmp("stylesheet").zero? }

      @__sheet ||= CSSStyleSheet.new(
        owner_node: self,
        href: href,
        media: media,
        title: @__node__["title"].to_s,
        type: (type.empty? ? "text/css" : type)
      )
    end

    def __js_get__(key)
      case key
      when "href"
        href
      when "rel"
        rel
      when "type"
        type
      when "media"
        media
      when "sizes"
        sizes
      when "hreflang"
        hreflang
      when "as"
        as_attr
      when "crossOrigin"
        crossorigin
      when "integrity"
        integrity
      when "referrerPolicy"
        referrer_policy
      when "sheet"
        sheet
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "href", "rel", "type", "media", "sizes", "hreflang", "as", "integrity"
        set_reflected_string(key, value)
      when "crossOrigin"
        set_reflected_string("crossorigin", value)
      when "referrerPolicy"
        set_reflected_string("referrerpolicy", value)
      else
        super
      end
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

    EMAIL_RE = /\A[^@\s]+@[^@\s]+\.[^@\s]+\z/
    URL_SCHEMES = %w[http:// https:// ftp://].freeze

    def initialize(host = nil)
      @host = host
    end

    # ---- Computed flags ----

    def value_missing
      return false unless @host && host_attr_present?("required")

      case host_type
      when "checkbox", "radio"
        !host_attr_present?("checked")
      else
        host_value.to_s.empty?
      end
    end

    def type_mismatch
      return false unless @host

      v = host_value.to_s
      return false if v.empty?

      case host_type
      when "email"
        !v.match?(EMAIL_RE)
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

      !Regexp.new("\\A(?:#{pat})\\z").match?(v)
    rescue RegexpError
      false
    end

    def too_long
      return false unless @host

      max = host_attr_value("maxlength").to_s
      return false if max.empty?

      max_n = max.to_i
      return false if max_n < 0

      host_value.to_s.length > max_n
    end

    def too_short
      return false unless @host

      min = host_attr_value("minlength").to_s
      return false if min.empty?

      min_n = min.to_i
      return false if min_n < 0

      v = host_value.to_s
      !v.empty? && v.length < min_n
    end

    def range_underflow
      return false unless numeric_host?

      min = host_attr_value("min").to_s
      return false if min.empty?

      num = numeric_value
      num && num < min.to_f
    end

    def range_overflow
      return false unless numeric_host?

      max = host_attr_value("max").to_s
      return false if max.empty?

      num = numeric_value
      num && num > max.to_f
    end

    def step_mismatch
      return false unless numeric_host?

      step = host_attr_value("step").to_s
      return false if step.empty? || step == "any"

      step_n = step.to_f
      return false if step_n <= 0

      num = numeric_value
      return false unless num

      base = host_attr_value("min").to_s
      base_n = base.empty? ? 0.0 : base.to_f
      ((num - base_n) / step_n - ((num - base_n) / step_n).round).abs > 1e-9
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
      end
    end

    private

    def host_value
      return "" unless @host

      @host.respond_to?(:value) ? @host.value : @host.__js_get__("value")
    end

    def host_attr_value(name)
      return "" unless @host

      @host.__node__[name].to_s
    end

    def host_attr_present?(name)
      return false unless @host

      @host.__node__.key?(name.to_s)
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
      @host.is_a?(HTMLInputElement) && %w[number range].include?(host_type)
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
    def value
      # Per spec, value defaults to text content if the `value`
      # attribute is absent.
      @__node__.key?("value") ? @__node__["value"].to_s : text_content
    end

    def value=(v)
      set_reflected_string("value", v)
    end

    def label
      @__node__.key?("label") ? @__node__["label"].to_s : text_content
    end

    def label=(v)
      set_reflected_string("label", v)
    end

    def selected
      reflected_boolean("selected")
    end

    def selected=(v)
      set_reflected_boolean("selected", v)
    end

    def default_selected
      selected
    end

    def default_selected=(v)
      self.selected = v
    end

    def disabled
      reflected_boolean("disabled")
    end

    def disabled=(v)
      set_reflected_boolean("disabled", v)
    end

    def text
      text_content
    end

    def text=(v)
      self.text_content = v
    end

    def form
      closest("form")
    end

    # `index` — position within the containing select's options list.
    def index
      sel = closest("select")
      return 0 unless sel

      sel.options.find_index { |o| o.__node__ == @__node__ } || 0
    end

    def __js_get__(key)
      case key
      when "value"
        value
      when "label"
        label
      when "selected"
        selected
      when "defaultSelected"
        default_selected
      when "disabled"
        disabled
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
      when "selected", "defaultSelected"
        self.selected = v
      when "disabled"
        self.disabled = v
      when "text"
        self.text = v
      else
        super
      end
    end
  end

  # `<optgroup>` — label + disabled, container for options.
  class HTMLOptGroupElement < HTMLElement
    def label
      reflected_string("label")
    end

    def label=(v)
      set_reflected_string("label", v)
    end

    def disabled
      reflected_boolean("disabled")
    end

    def disabled=(v)
      set_reflected_boolean("disabled", v)
    end

    def __js_get__(key)
      case key
      when "label"
        label
      when "disabled"
        disabled
      else
        super
      end
    end

    def __js_set__(key, v)
      case key
      when "label"
        self.label = v
      when "disabled"
        self.disabled = v
      else
        super
      end
    end
  end

  # `<textarea>` — multi-line text input.
  class HTMLTextAreaElement < HTMLElement
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

    def name
      reflected_string("name")
    end

    def name=(v)
      set_reflected_string("name", v)
    end

    def placeholder
      reflected_string("placeholder")
    end

    def placeholder=(v)
      set_reflected_string("placeholder", v)
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

    def wrap
      reflected_string("wrap")
    end

    def max_length
      (@__node__["maxlength"] || "-1").to_i
    end

    def min_length
      (@__node__["minlength"] || "-1").to_i
    end

    def text_length
      value.length
    end

    def autocomplete
      reflected_string("autocomplete")
    end

    def type
      "textarea"
    end

    def form
      closest("form")
    end

    def labels
      return [] if id.empty?

      @document.query_selector_all("label[for='#{id}']")
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
      !reflected_boolean("disabled") && !reflected_boolean("readonly")
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
      when "name"
        name
      when "placeholder"
        placeholder
      when "rows"
        rows
      when "cols"
        cols
      when "wrap"
        wrap
      when "maxLength"
        max_length
      when "minLength"
        min_length
      when "textLength"
        text_length
      when "autocomplete"
        autocomplete
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
      when "name"
        set_reflected_string("name", v)
      when "placeholder"
        set_reflected_string("placeholder", v)
      when "rows"
        self.rows = v
      when "cols"
        self.cols = v
      when "wrap"
        set_reflected_string("wrap", v)
      when "maxLength"
        set_reflected_string("maxlength", v.to_s)
      when "minLength"
        set_reflected_string("minlength", v.to_s)
      else
        super
      end
    end

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
    def html_for
      reflected_string("for")
    end

    def html_for=(v)
      set_reflected_string("for", v)
    end

    # `label.control` — the form control associated with this label.
    # Priority: explicit `for=`, then first form control descendant.
    def control
      target = html_for
      if !target.empty?
        @document.get_element_by_id(target)
      else
        query_selector("input, select, textarea, button, output, meter, progress")
      end
    end

    def form
      closest("form")
    end

    def __js_get__(key)
      case key
      when "htmlFor"
        html_for
      when "control"
        control
      when "form"
        form
      else
        super
      end
    end

    def __js_set__(key, v)
      case key
      when "htmlFor"
        self.html_for = v
      else
        super
      end
    end
  end

  # `<fieldset>` — disabled-state-propagating wrapper; exposes
  # `elements` collection like form.
  class HTMLFieldsetElement < HTMLElement
    def name
      reflected_string("name")
    end

    def name=(v)
      set_reflected_string("name", v)
    end

    def disabled
      reflected_boolean("disabled")
    end

    def disabled=(v)
      set_reflected_boolean("disabled", v)
    end

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
          .__node__
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

    def check_validity
      true
    end

    def report_validity
      true
    end

    def __js_get__(key)
      case key
      when "name"
        name
      when "disabled"
        disabled
      when "type"
        type
      when "form"
        form
      when "elements"
        elements
      when "validity"
        validity
      else
        super
      end
    end

    def __js_set__(key, v)
      case key
      when "name"
        self.name = v
      when "disabled"
        self.disabled = v
      else
        super
      end
    end
  end

  # `<output>` — calculation result element.
  class HTMLOutputElement < HTMLElement
    def value
      text_content
    end

    def value=(v)
      self.text_content = v
    end

    def default_value
      text_content
    end

    def default_value=(v)
      self.text_content = v
    end

    def name
      reflected_string("name")
    end

    def name=(v)
      set_reflected_string("name", v)
    end

    # `for` attribute is a space-separated list of IDs.
    def html_for_tokens
      reflected_string("for").split(/\s+/).reject(&:empty?)
    end

    def form
      closest("form")
    end

    def labels
      return [] if id.empty?

      @document.query_selector_all("label[for='#{id}']")
    end

    def type
      "output"
    end

    def validity
      ValidityState.new
    end

    def check_validity
      true
    end

    def report_validity
      true
    end

    def __js_get__(key)
      case key
      when "value"
        value
      when "defaultValue"
        default_value
      when "name"
        name
      when "type"
        type
      when "form"
        form
      when "labels"
        labels
      when "validity"
        validity
      when "htmlFor"
        reflected_string("for")
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
      when "name"
        self.name = v
      when "htmlFor"
        set_reflected_string("for", v)
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
    def name
      reflected_string("name")
    end

    def name=(v)
      set_reflected_string("name", v)
    end

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
      @__manual_assignment = nodes.flatten.select { |n| n.respond_to?(:__node__) }
      dispatch_event(Event.new("slotchange", "bubbles" => true))
      nil
    end

    def __js_get__(key)
      case key
      when "name"
        name
      when "assignedNodes"
        assigned_nodes
      when "assignedElements"
        assigned_elements
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "name"
        self.name = value
      else
        super
      end
    end

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
      sr = @document.__shadow_root_containing__(@__node__)
      return [] unless sr

      host = sr.host
      return [] unless host

      slot_name = name
      # Manual mode honors the explicit list.
      if sr.slot_assignment == "manual" && @__manual_assignment
        return @__manual_assignment
      end

      host
        .__node__
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
    def name
      reflected_string("name")
    end

    def name=(v)
      set_reflected_string("name", v)
    end

    def multiple
      reflected_boolean("multiple")
    end

    def multiple=(v)
      set_reflected_boolean("multiple", v)
    end

    def size
      @__node__["size"].to_s.to_i
    end

    # `options` — all <option> descendants (including those inside
    # <optgroup>). Live HTMLOptionsCollection (HTMLCollection +
    # add/remove/selectedIndex/length= helpers).
    def options
      el = self
      HTMLOptionsCollection.new(self) do
        el.__node__.css("option").map { |n| el.document.wrap_node(n) }.compact
      end
    end

    # `selectedOptions` — live collection of options with `selected`
    # attribute. When nothing is explicitly selected, browsers fall
    # back to the first option for non-multiple selects.
    def selected_options
      el = self
      HTMLCollection.new do
        opts = el.__node__.css("option").map { |n| el.document.wrap_node(n) }.compact
        chosen = opts.select { |o| o.__node__.key?("selected") }
        next chosen unless chosen.empty?
        next [] if el.multiple

        opts.first ? [opts.first] : []
      end
    end

    def length
      options.size
    end

    def form
      closest("form")
    end

    # `selectedIndex` — first option with `selected`, or 0 if none and
    # not multiple, or -1 if multiple and none.
    def selected_index
      opts = options
      idx = opts.find_index { |o| o.__node__.key?("selected") }
      return idx if idx

      multiple ? -1 : (opts.empty? ? -1 : 0)
    end

    def selected_index=(i)
      opts = options
      opts.each_with_index do |o, idx|
        if idx == i.to_i
          o.set_attribute("selected", "")
        elsif o.__node__.key?("selected")
          o.remove_attribute("selected")
        end
      end
    end

    # `value` of the select = value of the selected option, or "".
    def value
      opts = options
      sel = opts.find { |o| o.__node__.key?("selected") } || opts.first
      sel ? (sel.__node__["value"] || sel.text_content).to_s : ""
    end

    def value=(new_value)
      target = options.find { |o| (o.__node__["value"] || o.text_content).to_s == new_value.to_s }
      return unless target

      options.each { |o| o.remove_attribute("selected") if o.__node__.key?("selected") }
      target.set_attribute("selected", "")
    end

    # `select.item(i)` — returns the option at index i.
    def item(i)
      options[i.to_i]
    end

    # `select.add(option, before)` — appends or inserts before `before`.
    def add(option, before = nil)
      return nil unless option.respond_to?(:__node__)

      if before.respond_to?(:__node__)
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
      !reflected_boolean("disabled")
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
      when "name"
        name
      when "multiple"
        multiple
      when "size"
        size
      when "selectedIndex"
        selected_index
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
        super
      end
    end

    def __js_set__(key, val)
      case key
      when "value"
        self.value = val
      when "name"
        set_reflected_string("name", val)
      when "multiple"
        set_reflected_boolean("multiple", val)
      when "selectedIndex"
        self.selected_index = val
      else
        super
      end
    end

    def __js_call__(method, args)
      case method
      when "item"
        item(args[0])
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
    def open
      reflected_boolean("open")
    end

    def open=(v)
      set_reflected_boolean("open", v)
    end

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

    def show_modal
      self.open = true
      nil
    end

    def close(value = nil)
      self.open = false
      @return_value = value.to_s unless value.nil?
      dispatch_event(Event.new("close", "bubbles" => false, "cancelable" => false))
      nil
    end

    def __js_get__(key)
      case key
      when "open"
        open
      when "returnValue"
        return_value
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "open"
        self.open = value
      when "returnValue"
        self.return_value = value
      else
        super
      end
    end

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

  # `<details>` — `open` reflected boolean. Toggling it fires a
  # `toggle` event (non-bubbling per spec).
  class HTMLDetailsElement < HTMLElement
    def open
      reflected_boolean("open")
    end

    def open=(v)
      was = open
      set_reflected_boolean("open", v)
      now = open
      return if was == now

      dispatch_event(Event.new("toggle", "bubbles" => false, "cancelable" => false))
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
  end

  # `<meter>` — gauge with `value` / `min` / `max` (default 0/0/1)
  # plus `low` / `high` / `optimum`. All numeric; `labels` via the
  # standard `<label for="...">` association.
  class HTMLMeterElement < HTMLElement
    def value
      numeric_attr("value", 0.0)
    end

    def value=(v)
      set_reflected_string("value", v.to_s)
    end

    def min
      numeric_attr("min", 0.0)
    end

    def min=(v)
      set_reflected_string("min", v.to_s)
    end

    def max
      numeric_attr("max", 1.0)
    end

    def max=(v)
      set_reflected_string("max", v.to_s)
    end

    def low
      numeric_attr("low", min)
    end

    def low=(v)
      set_reflected_string("low", v.to_s)
    end

    def high
      numeric_attr("high", max)
    end

    def high=(v)
      set_reflected_string("high", v.to_s)
    end

    def optimum
      numeric_attr("optimum", (min + max) / 2.0)
    end

    def optimum=(v)
      set_reflected_string("optimum", v.to_s)
    end

    def labels
      return [] if id.empty?

      @document.query_selector_all("label[for='#{id}']")
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
      when "value", "min", "max", "low", "high", "optimum"
        set_reflected_string(key, v.to_s)
      else
        super
      end
    end

    private

    def numeric_attr(name, default)
      raw = @__node__[name].to_s
      raw.empty? ? default : Float(raw) rescue default
    end
  end

  # `<progress>` — `value` and `max` (default max=1). `position`
  # returns `value / max` for a "determinate" progress bar, or -1
  # when no value is set ("indeterminate").
  class HTMLProgressElement < HTMLElement
    def value
      raw = @__node__["value"].to_s
      raw.empty? ? nil : Float(raw)
    rescue ArgumentError
      nil
    end

    def value=(v)
      set_reflected_string("value", v.to_s)
    end

    def max
      raw = @__node__["max"].to_s
      raw.empty? ? 1.0 : (Float(raw) rescue 1.0)
    end

    def max=(v)
      set_reflected_string("max", v.to_s)
    end

    # `position` = value/max for determinate progress; -1 if value
    # was never set (indeterminate).
    def position
      v = value
      return -1.0 if v.nil?

      m = max
      m <= 0 ? 1.0 : (v / m)
    end

    def labels
      return [] if id.empty?

      @document.query_selector_all("label[for='#{id}']")
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
      when "value", "max"
        set_reflected_string(key, v.to_s)
      else
        super
      end
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
    def cell_index
      row = closest("tr")
      return -1 unless row

      row.cells.find_index { |c| c.__node__ == @__node__ } || -1
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

    def headers
      reflected_string("headers")
    end

    def headers=(v)
      set_reflected_string("headers", v)
    end

    # `scope` / `abbr` are only meaningful on `<th>`, but the IDL
    # exposes them on the cell element either way.
    def scope
      reflected_string("scope")
    end

    def scope=(v)
      set_reflected_string("scope", v)
    end

    def abbr
      reflected_string("abbr")
    end

    def abbr=(v)
      set_reflected_string("abbr", v)
    end

    def __js_get__(key)
      case key
      when "cellIndex"
        cell_index
      when "colSpan"
        col_span
      when "rowSpan"
        row_span
      when "headers"
        headers
      when "scope"
        scope
      when "abbr"
        abbr
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
      when "headers"
        self.headers = value
      when "scope"
        self.scope = value
      when "abbr"
        self.abbr = value
      else
        super
      end
    end
  end

  # `<tr>` — table row. `cells` are direct `<td>`/`<th>` children.
  # `rowIndex` walks the enclosing table; `sectionRowIndex` walks
  # the enclosing thead/tbody/tfoot.
  class HTMLTableRowElement < HTMLElement
    def cells
      el = self
      HTMLCollection.new do
        el
          .__node__
          .element_children
          .select { |n| %w[td th].include?(n.name) }
          .map { |n| el.document.wrap_node(n) }
          .compact
      end
    end

    def row_index
      table = closest("table")
      return -1 unless table

      table.rows.find_index { |r| r.__node__ == @__node__ } || -1
    end

    def section_row_index
      section = @__node__.parent
      return -1 unless section && section.element? && %w[thead tbody tfoot].include?(section.name)

      section.element_children.select { |n| n.name == "tr" }.find_index { |n| n == @__node__ } || -1
    end

    # `insertCell(index)` — adds a `<td>` at the given index
    # (defaults to end). Returns the new cell.
    def insert_cell(index = -1)
      cell = @document.create_element("td")
      list = cells
      if index.to_i == -1 || index.to_i >= list.size
        append_child(cell)
      else
        insert_before(cell, list[index.to_i])
      end

      cell
    end

    def delete_cell(index)
      target = cells[index.to_i]
      target&.remove
      nil
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
    def rows
      el = self
      HTMLCollection.new do
        el
          .__node__
          .element_children
          .select { |n| n.name == "tr" }
          .map { |n| el.document.wrap_node(n) }
          .compact
      end
    end

    def insert_row(index = -1)
      tr = @document.create_element("tr")
      list = rows
      if index.to_i == -1 || index.to_i >= list.size
        append_child(tr)
      else
        insert_before(tr, list[index.to_i])
      end

      tr
    end

    def delete_row(index)
      rows[index.to_i]&.remove
      nil
    end

    def __js_get__(key)
      key == "rows" ? rows : super
    end

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
    def caption
      @__node__.element_children.find { |n| n.name == "caption" }&.then { |n| @document.wrap_node(n) }
    end

    def caption=(new_caption)
      delete_caption
      return unless new_caption.respond_to?(:__node__)

      first = @__node__.children.first
      first ? first.add_previous_sibling(new_caption.__node__) : @__node__.add_child(new_caption.__node__)
    end

    def t_head
      @__node__.element_children.find { |n| n.name == "thead" }&.then { |n| @document.wrap_node(n) }
    end

    def t_foot
      @__node__.element_children.find { |n| n.name == "tfoot" }&.then { |n| @document.wrap_node(n) }
    end

    def t_bodies
      el = self
      HTMLCollection.new do
        el
          .__node__
          .element_children
          .select { |n| n.name == "tbody" }
          .map { |n| el.document.wrap_node(n) }
          .compact
      end
    end

    def rows
      el = self
      HTMLCollection.new do
        ordered = []
        head = el.__node__.element_children.find { |n| n.name == "thead" }
        bodies = el.__node__.element_children.select { |n| n.name == "tbody" }
        direct = el.__node__.element_children.select { |n| n.name == "tr" }
        foot = el.__node__.element_children.find { |n| n.name == "tfoot" }
        [head, *bodies, foot].compact.each do |sec|
          sec.element_children.select { |n| n.name == "tr" }.each { |n| ordered << n }
        end

        direct.each { |n| ordered << n }
        ordered.map { |n| el.document.wrap_node(n) }.compact
      end
    end

    def create_caption
      existing = caption
      return existing if existing

      cap = @document.create_element("caption")
      first = @__node__.children.first
      first ? first.add_previous_sibling(cap.__node__) : @__node__.add_child(cap.__node__)
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
        cap.__node__.add_next_sibling(head.__node__)
      else
        first = @__node__.children.first
        first ? first.add_previous_sibling(head.__node__) : @__node__.add_child(head.__node__)
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
      @__node__.add_child(foot.__node__)
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
        last_tbody.__node__.add_next_sibling(tb.__node__)
      else
        @__node__.add_child(tb.__node__)
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
        section = anchor.__node__.parent
        if section
          anchor.__node__.add_previous_sibling(tr.__node__)
          @document.notify_child_list_mutation(target_node: section, added_nodes: [tr.__node__], removed_nodes: [])
        end
      end

      tr
    end

    def delete_row(index)
      rows[index.to_i]&.remove
      nil
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
      else
        super
      end
    end

    def __js_call__(method, args)
      case method
      when "insertRow"
        insert_row(args[0] || -1)
      when "deleteRow"
        delete_row(args[0])
      when "createCaption"
        create_caption
      when "deleteCaption"
        delete_caption
      when "createTHead"
        create_t_head
      when "deleteTHead"
        delete_t_head
      when "createTFoot"
        create_t_foot
      when "deleteTFoot"
        delete_t_foot
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
    NETWORK_EMPTY = 0
    NETWORK_IDLE = 1
    NETWORK_LOADING = 2
    NETWORK_NO_SOURCE = 3

    HAVE_NOTHING = 0
    HAVE_METADATA = 1
    HAVE_CURRENT_DATA = 2
    HAVE_FUTURE_DATA = 3
    HAVE_ENOUGH_DATA = 4

    def src
      reflected_string("src")
    end

    def src=(v)
      set_reflected_string("src", v)
    end

    def current_src
      src
    end

    def preload
      reflected_string("preload")
    end

    def preload=(v)
      set_reflected_string("preload", v)
    end

    def crossorigin
      reflected_string("crossorigin")
    end

    def autoplay
      reflected_boolean("autoplay")
    end

    def autoplay=(v)
      set_reflected_boolean("autoplay", v)
    end

    def loop_
      reflected_boolean("loop")
    end

    def loop_=(v)
      set_reflected_boolean("loop", v)
    end

    def controls
      reflected_boolean("controls")
    end

    def controls=(v)
      set_reflected_boolean("controls", v)
    end

    def muted
      @__muted == true || reflected_boolean("muted")
    end

    def muted=(v)
      @__muted = !!v
    end

    def default_muted
      reflected_boolean("muted")
    end

    def default_muted=(v)
      set_reflected_boolean("muted", v)
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
      when "src"
        src
      when "currentSrc"
        current_src
      when "preload"
        preload
      when "crossOrigin"
        crossorigin
      when "autoplay"
        autoplay
      when "loop"
        loop_
      when "controls"
        controls
      when "muted"
        muted
      when "defaultMuted"
        default_muted
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
      when "src"
        self.src = value
      when "preload"
        self.preload = value
      when "autoplay"
        self.autoplay = value
      when "loop"
        self.loop_ = value
      when "controls"
        self.controls = value
      when "muted"
        self.muted = value
      when "defaultMuted"
        self.default_muted = value
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
    def poster
      reflected_string("poster")
    end

    def poster=(v)
      set_reflected_string("poster", v)
    end

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

    def plays_inline
      reflected_boolean("playsinline")
    end

    def plays_inline=(v)
      set_reflected_boolean("playsinline", v)
    end

    def __js_get__(key)
      case key
      when "poster"
        poster
      when "width"
        width
      when "height"
        height
      when "videoWidth"
        video_width
      when "videoHeight"
        video_height
      when "playsInline"
        plays_inline
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "poster"
        self.poster = value
      when "width"
        self.width = value
      when "height"
        self.height = value
      when "playsInline"
        self.plays_inline = value
      else
        super
      end
    end
  end

  class HTMLSourceElement < HTMLElement
    def src
      reflected_string("src")
    end

    def src=(v)
      set_reflected_string("src", v)
    end

    def type
      reflected_string("type")
    end

    def type=(v)
      set_reflected_string("type", v)
    end

    def media
      reflected_string("media")
    end

    def media=(v)
      set_reflected_string("media", v)
    end

    def srcset
      reflected_string("srcset")
    end

    def srcset=(v)
      set_reflected_string("srcset", v)
    end

    def sizes
      reflected_string("sizes")
    end

    def sizes=(v)
      set_reflected_string("sizes", v)
    end

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
      when "src"
        src
      when "type"
        type
      when "media"
        media
      when "srcset"
        srcset
      when "sizes"
        sizes
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
      when "src", "type", "media", "srcset", "sizes"
        set_reflected_string(key, value)
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
    NONE = 0
    LOADING = 1
    LOADED = 2
    ERROR = 3

    def kind
      reflected_string("kind")
    end

    def kind=(v)
      set_reflected_string("kind", v)
    end

    def src
      reflected_string("src")
    end

    def src=(v)
      set_reflected_string("src", v)
    end

    def srclang
      reflected_string("srclang")
    end

    def srclang=(v)
      set_reflected_string("srclang", v)
    end

    def label
      reflected_string("label")
    end

    def label=(v)
      set_reflected_string("label", v)
    end

    def default_
      reflected_boolean("default")
    end

    def default_=(v)
      set_reflected_boolean("default", v)
    end

    def ready_state
      NONE
    end

    def __js_get__(key)
      case key
      when "kind"
        kind
      when "src"
        src
      when "srclang"
        srclang
      when "label"
        label
      when "default"
        default_
      when "readyState"
        ready_state
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "kind", "src", "srclang", "label"
        set_reflected_string(key, value)
      when "default"
        self.default_ = value
      else
        super
      end
    end
  end

  class HTMLIFrameElement < HTMLElement
    def src
      reflected_string("src")
    end

    def src=(v)
      set_reflected_string("src", v)
    end

    def srcdoc
      reflected_string("srcdoc")
    end

    def srcdoc=(v)
      set_reflected_string("srcdoc", v)
    end

    def name
      reflected_string("name")
    end

    def name=(v)
      set_reflected_string("name", v)
    end

    def sandbox
      reflected_string("sandbox")
    end

    def sandbox=(v)
      set_reflected_string("sandbox", v)
    end

    def allow
      reflected_string("allow")
    end

    def allow=(v)
      set_reflected_string("allow", v)
    end

    def allow_fullscreen
      reflected_boolean("allowfullscreen")
    end

    def allow_fullscreen=(v)
      set_reflected_boolean("allowfullscreen", v)
    end

    def referrer_policy
      reflected_string("referrerpolicy")
    end

    def referrer_policy=(v)
      set_reflected_string("referrerpolicy", v)
    end

    def loading
      reflected_string("loading")
    end

    def loading=(v)
      set_reflected_string("loading", v)
    end

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
      when "src"
        src
      when "srcdoc"
        srcdoc
      when "name"
        name
      when "sandbox"
        sandbox
      when "allow"
        allow
      when "allowFullscreen"
        allow_fullscreen
      when "referrerPolicy"
        referrer_policy
      when "loading"
        loading
      when "width"
        width
      when "height"
        height
      when "contentDocument"
        content_document
      when "contentWindow"
        content_window
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "src", "srcdoc", "name", "sandbox", "allow", "loading"
        set_reflected_string(key, value)
      when "allowFullscreen"
        self.allow_fullscreen = value
      when "referrerPolicy"
        set_reflected_string("referrerpolicy", value)
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
    def start
      (@__node__["start"] || "1").to_i
    end

    def start=(v)
      set_reflected_string("start", v.to_s)
    end

    def reversed
      reflected_boolean("reversed")
    end

    def reversed=(v)
      set_reflected_boolean("reversed", v)
    end

    def type
      reflected_string("type")
    end

    def type=(v)
      set_reflected_string("type", v)
    end

    def __js_get__(key)
      case key
      when "start"
        start
      when "reversed"
        reversed
      when "type"
        type
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "start"
        self.start = value
      when "reversed"
        self.reversed = value
      when "type"
        self.type = value
      else
        super
      end
    end
  end

  class HTMLUListElement < HTMLElement
  end

  class HTMLLIElement < HTMLElement
    def value
      @__node__["value"]&.to_i
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
    def date_time
      reflected_string("datetime")
    end

    def date_time=(v)
      set_reflected_string("datetime", v)
    end

    def __js_get__(key)
      key == "dateTime" ? date_time : super
    end

    def __js_set__(key, value)
      key == "dateTime" ? (self.date_time = value) : super
    end
  end

  class HTMLDataElement < HTMLElement
    def value
      reflected_string("value")
    end

    def value=(v)
      set_reflected_string("value", v)
    end

    def __js_get__(key)
      key == "value" ? value : super
    end

    def __js_set__(key, value)
      key == "value" ? (self.value = value) : super
    end
  end

  class HTMLAreaElement < HTMLElement
    def alt
      reflected_string("alt")
    end

    def alt=(v)
      set_reflected_string("alt", v)
    end

    def coords
      reflected_string("coords")
    end

    def coords=(v)
      set_reflected_string("coords", v)
    end

    def shape
      reflected_string("shape")
    end

    def shape=(v)
      set_reflected_string("shape", v)
    end

    def href
      reflected_string("href")
    end

    def href=(v)
      set_reflected_string("href", v)
    end

    def target
      reflected_string("target")
    end

    def target=(v)
      set_reflected_string("target", v)
    end

    def rel
      reflected_string("rel")
    end

    def rel=(v)
      set_reflected_string("rel", v)
    end

    def __js_get__(key)
      case key
      when "alt"
        alt
      when "coords"
        coords
      when "shape"
        shape
      when "href"
        href
      when "target"
        target
      when "rel"
        rel
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "alt", "coords", "shape", "href", "target", "rel"
        set_reflected_string(key, value)
      else
        super
      end
    end
  end

  class HTMLMapElement < HTMLElement
    def name
      reflected_string("name")
    end

    def name=(v)
      set_reflected_string("name", v)
    end

    def areas
      HTMLCollection.new do
        @__node__.css("area").map { |n| @document.wrap_node(n) }.compact
      end
    end

    def __js_get__(key)
      case key
      when "name"
        name
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
    def data
      reflected_string("data")
    end

    def data=(v)
      set_reflected_string("data", v)
    end

    def type
      reflected_string("type")
    end

    def type=(v)
      set_reflected_string("type", v)
    end

    def name
      reflected_string("name")
    end

    def name=(v)
      set_reflected_string("name", v)
    end

    def use_map
      reflected_string("usemap")
    end

    def use_map=(v)
      set_reflected_string("usemap", v)
    end

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
      when "data"
        data
      when "type"
        type
      when "name"
        name
      when "useMap"
        use_map
      when "width"
        width
      when "height"
        height
      when "contentDocument"
        content_document
      when "contentWindow"
        content_window
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "data", "type", "name"
        set_reflected_string(key, value)
      when "useMap"
        set_reflected_string("usemap", value)
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
    def src
      reflected_string("src")
    end

    def src=(v)
      set_reflected_string("src", v)
    end

    def type
      reflected_string("type")
    end

    def type=(v)
      set_reflected_string("type", v)
    end

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
      when "src"
        src
      when "type"
        type
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
      when "src", "type"
        set_reflected_string(key, value)
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
    def href
      reflected_string("href")
    end

    def href=(v)
      set_reflected_string("href", v)
    end

    def target
      reflected_string("target")
    end

    def target=(v)
      set_reflected_string("target", v)
    end

    def __js_get__(key)
      case key
      when "href"
        href
      when "target"
        target
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "href", "target"
        set_reflected_string(key, value)
      else
        super
      end
    end
  end

  class HTMLMetaElement < HTMLElement
    def name
      reflected_string("name")
    end

    def name=(v)
      set_reflected_string("name", v)
    end

    def content
      reflected_string("content")
    end

    def content=(v)
      set_reflected_string("content", v)
    end

    def charset
      reflected_string("charset")
    end

    def charset=(v)
      set_reflected_string("charset", v)
    end

    def http_equiv
      reflected_string("http-equiv")
    end

    def http_equiv=(v)
      set_reflected_string("http-equiv", v)
    end

    def __js_get__(key)
      case key
      when "name"
        name
      when "content"
        content
      when "charset"
        charset
      when "httpEquiv"
        http_equiv
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "name", "content", "charset"
        set_reflected_string(key, value)
      when "httpEquiv"
        set_reflected_string("http-equiv", value)
      else
        super
      end
    end
  end

  class HTMLStyleElement < HTMLElement
    def type
      reflected_string("type")
    end

    def type=(v)
      set_reflected_string("type", v)
    end

    def media
      reflected_string("media")
    end

    def media=(v)
      set_reflected_string("media", v)
    end

    def disabled
      @__disabled == true
    end

    def disabled=(v)
      @__disabled = !!v
    end

    # `style.sheet` — always non-nil for `<style>` (in browsers the
    # text content is parsed; we hand back an empty sheet stub that
    # consumers can manipulate via insertRule/deleteRule).
    def sheet
      @__sheet ||= CSSStyleSheet.new(
        owner_node: self,
        media: media,
        title: @__node__["title"].to_s,
        type: (type.empty? ? "text/css" : type)
      )
    end

    def __js_get__(key)
      case key
      when "type"
        type
      when "media"
        media
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
      when "type", "media"
        set_reflected_string(key, value)
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
    def cite
      reflected_string("cite")
    end

    def cite=(v)
      set_reflected_string("cite", v)
    end

    def __js_get__(key)
      key == "cite" ? cite : super
    end

    def __js_set__(key, value)
      key == "cite" ? (self.cite = value) : super
    end
  end

  class HTMLModElement < HTMLElement
    def cite
      reflected_string("cite")
    end

    def cite=(v)
      set_reflected_string("cite", v)
    end

    def date_time
      reflected_string("datetime")
    end

    def date_time=(v)
      set_reflected_string("datetime", v)
    end

    def __js_get__(key)
      case key
      when "cite"
        cite
      when "dateTime"
        date_time
      else
        super
      end
    end

    def __js_set__(key, value)
      case key
      when "cite"
        self.cite = value
      when "dateTime"
        self.date_time = value
      else
        super
      end
    end
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

  # Look up the subclass for a given HTML tag. Document#wrap_node
  # consults this map; defaults to plain Element.
  HTML_ELEMENT_CLASSES = {
    "a" => HTMLAnchorElement,
    "form" => HTMLFormElement,
    "input" => HTMLInputElement,
    "button" => HTMLButtonElement,
    "img" => HTMLImageElement,
    "script" => HTMLScriptElement,
    "link" => HTMLLinkElement,
    "select" => HTMLSelectElement,
    "option" => HTMLOptionElement,
    "optgroup" => HTMLOptGroupElement,
    "textarea" => HTMLTextAreaElement,
    "label" => HTMLLabelElement,
    "fieldset" => HTMLFieldsetElement,
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
    "html" => HTMLHtmlElement
  }.freeze

  SVG_NAMESPACE_URI = "http://www.w3.org/2000/svg"

  def self.element_class_for(tag_name, namespace_uri = nil)
    if namespace_uri == SVG_NAMESPACE_URI
      SVG_ELEMENT_CLASSES[tag_name.to_s.downcase] || SVGElement
    else
      HTML_ELEMENT_CLASSES[tag_name.to_s.downcase] || Element
    end
  end
end
