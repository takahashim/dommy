# frozen_string_literal: true

require_relative "../internal/directionality"
require_relative "../internal/rendered_text/collector"
require_relative "../internal/rendered_text/fragment"

module Dommy
  # The HTMLElement base and the behaviour mixins its subclasses share.
  #
  # One of the HTML element groups; html_elements.rb lists them all.
  # Base for specialized HTMLElement subclasses. Inherits reflection
  # helpers from Internal::ReflectedAttributes (also shared with
  # SVGElement).
  class HTMLElement < Element
    include Internal::ReflectedAttributes
    include Internal::HTMLOrSVGOrMathMLElement
    include Internal::ElementCSSInlineStyle
    include Internal::ElementPopover
    # The plain reflections — `lang` and `title` (this element's own content
    # attribute, "" when absent: not the language it inherits for matching or
    # an ancestor's advisory title), `accessKey`, `inert`, `headingOffset`
    # (0 to 8) — and every subclass's are declared from the IDL
    # (Internal::IdlReflection, run once all element classes are defined).
    # The virtual keyboard's enter key and layout, limited to only known
    # values (HTML §6.8.5).
    reflect_enumerated enter_key_hint: { attr: "enterkeyhint", js: "enterKeyHint",
                                         keywords: %w[enter done go next previous search send] },
                       input_mode: { attr: "inputmode", js: "inputMode",
                                     keywords: %w[none text tel url email numeric decimal search] }

    # `popover` (HTML §6.12), limited to its keywords: null without the
    # attribute, "auto" for an empty one, "manual" for any other value.
    reflect_enumerated popover: Internal::ElementPopover::POPOVER_STATES
    js_accessor :hidden, :translate
    js_readable :access_key_label, :offset_parent, :offset_top, :offset_left, :offset_width, :offset_height

    # `hidden` (HTML §6.1), a `(boolean or unrestricted double or
    # DOMString)?`: "until-found" for the hidden-until-found state (the
    # keyword, matched ASCII case-insensitively), true for any other value,
    # false without the attribute.
    def hidden
      value = __internal_attribute_value__("hidden")
      return false if value.nil?

      value.casecmp?("until-found") ? "until-found" : true
    end

    # "until-found" writes that state; false, "", null, 0 and NaN remove the
    # attribute; anything else writes it empty.
    def hidden=(value)
      if value.is_a?(String) && value.casecmp?("until-found")
        __internal_set_attribute_value__("hidden", "until-found")
      elsif hidden_removed_by?(value)
        remove_attribute_ns(nil, "hidden")
      else
        __internal_set_attribute_value__("hidden", "")
      end
    end

    def hidden_removed_by?(value) = !Internal::WebIDL.boolean(value)
    private :hidden_removed_by?

    # `translate`: the element's translation mode — the nearest
    # ancestor-or-self with a valid translate attribute decides ("yes" or ""
    # translates, "no" does not); with none, the root translates. The setter
    # writes "yes" or "no".
    def translate
      node = self
      while node
        case node.__internal_attribute_value__("translate")&.downcase(:ascii)
        when "yes", "" then return true
        when "no" then return false
        end
        node = node.parent_element
      end
      true
    end

    def translate=(value)
      __internal_set_attribute_value__("translate", Internal::WebIDL.boolean(value) ? "yes" : "no")
    end

    # `accessKeyLabel`: the `accesskey` content attribute is a set of
    # one-code-point candidates; a single valid candidate yields a
    # (modifier-prefixed) label, anything else (empty, or multiple /
    # multi-char tokens) yields the empty string. The exact modifier varies by
    # platform — tests only assert non-empty vs empty.
    def access_key_label
      keys = __internal_attribute_value__("accesskey").to_s.split(/[ \t\n\f\r]+/).reject(&:empty?)
      return "" unless keys.length == 1 && keys.first.length == 1

      "Alt+#{keys.first.upcase}"
    end

    # cssom-view's offsets: nothing lays the element out, so it has no offset
    # parent, sits at 0, and measures what its layout size does.
    def offset_parent = nil
    def offset_top = 0
    def offset_left = 0
    def offset_width = layout_size(:width)
    def offset_height = layout_size(:height)

    # `click()` runs the HTML activation behavior around the dispatched event:
    # pre-click activation may change state (e.g. toggle a checkbox), the click
    # is dispatched, and then either the activation behavior runs (not canceled)
    # or the pre-click state is restored (default prevented). Elements with no
    # activation behavior (the default) just dispatch the event.
    def click
      # HTML click(): "if this element is a form control that is disabled,
      # then return" — a disabled control fires no event at all, so a listener
      # bound to it never runs.
      return false if __internal_actually_disabled__

      # HTML click(): "if this element's click in progress flag is set, then
      # return". It is what stops a label from clicking itself to death: the
      # label's activation behavior clicks its labeled control, the control's
      # click bubbles back to the label, and the label forwards it again. A
      # <meter>, <output> or <progress> in a <label> did exactly that until the
      # stack ran out, because the "leave interactive content alone" guard in
      # the label does not cover a control that is not interactive content.
      return false if @__click_in_progress

      @__click_in_progress = true
      begin
        # Everything else (picking the activation target, the pre-activation
        # toggle, running or undoing the activation behavior) is dispatch's job,
        # so a synthesized `dispatchEvent(new MouseEvent("click"))` behaves
        # identically to click().
        #
        # HTML "fire a synthetic pointer event" named click, not trusted: a
        # PointerEvent that bubbles, is cancelable and composed, with the
        # window as its view — and, per Pointer Events, pointerId -1 and an
        # empty pointerType, as a click no pointer made.
        view = @document.default_view
        dispatch_event(PointerEvent.new("click", "bubbles" => true, "cancelable" => true, "composed" => true,
          "button" => 0, "pointerId" => -1, "pointerType" => "", "view" => view.is_a?(Window) ? view : nil))
      ensure
        # Not a method-level `ensure`: the early return above must not clear the
        # flag the click it returned from is still holding.
        @__click_in_progress = false
      end
    end

    js_methods %w[click]
    def __js_call__(method, args)
      case method
      when "click"
        click
      else
        super
      end
    end

    # The elements whose tabIndex is 0 without a tabindex attribute.
    TAB_INDEX_ZERO = %w[a area button frame iframe input object select textarea].freeze

    # tabIndex's default (HTML §6.6.3): 0 for the elements above and a
    # summary that is its details' summary, -1 for the rest.
    def default_tab_index = TAB_INDEX_ZERO.include?(local_name) || __internal_summary_details__ ? 0 : -1

    js_accessor :draggable, :spellcheck
    reflect_setter writing_suggestions: { attr: "writingsuggestions", js: "writingSuggestions" }

    # `draggable` (HTML §6.11.7): the draggable attribute's "true" or
    # "false", matched ASCII case-insensitively; otherwise (auto) an img, or
    # an `a` with an href, is draggable and nothing else is.
    def draggable
      case __internal_attribute_value__("draggable")&.downcase(:ascii)
      when "true" then true
      when "false" then false
      else local_name == "img" || (local_name == "a" && __internal_has_attribute__?("href"))
      end
    end

    def draggable=(value)
      __internal_set_attribute_value__("draggable", Internal::WebIDL.boolean(value) ? "true" : "false")
    end

    # `spellcheck` (HTML §6.8.4): "true" or "" checks spelling and "false"
    # does not; with neither, the element follows its parent, and the root
    # checks — the default Dommy picks, as Chromium does.
    def spellcheck = inherited_hint("spellcheck", "true", "false") != false

    def spellcheck=(value)
      __internal_set_attribute_value__("spellcheck", Internal::WebIDL.boolean(value) ? "true" : "false")
    end

    # `writingSuggestions` (HTML §6.8.8): "false" when the attribute says so,
    # or when it says nothing and the parent's is "false"; else "true".
    def writing_suggestions = inherited_hint("writingsuggestions", "true", "false") == false ? "false" : "true"

    reflect_setter :autocapitalize
    js_accessor :autocorrect

    # The autocapitalize keywords and the hint each names (HTML §6.8.6).
    AUTOCAPITALIZE_HINTS = {
      "off" => "none", "none" => "none", "on" => "sentences", "sentences" => "sentences",
      "words" => "words", "characters" => "characters",
    }.freeze
    # The "autocapitalize-and-autocorrect inheriting elements", which take
    # their form owner's hint when they give none.
    AUTOCAPITALIZE_INHERITING = %w[button fieldset input output select textarea].freeze
    # The input types that never autocorrect.
    NO_AUTOCORRECT_TYPES = %w[url email password].freeze

    # `autocapitalize`: the element's own autocapitalization hint — its
    # attribute's state, else its form owner's when it is one of the
    # inheriting elements — or "" when there is none. A value that is no
    # keyword, the empty one included, is the sentences state (the
    # attribute's invalid value default), and is not left to the form owner.
    def autocapitalize = own_autocapitalization_hint || ""

    def own_autocapitalization_hint
      value = __internal_attribute_value__("autocapitalize")
      return AUTOCAPITALIZE_HINTS.fetch(value.downcase(:ascii), "sentences") if value

      autocorrect_form_owner&.own_autocapitalization_hint
    end
    protected :own_autocapitalization_hint

    # `autocorrect` (HTML §6.8.7): the used autocorrection state — off for a
    # url, email or password input; else the attribute's ("off" turns it
    # off, anything else on), or the form owner's for an inheriting element;
    # else on. The setter writes "on" or "off".
    def autocorrect
      return false if local_name == "input" && NO_AUTOCORRECT_TYPES.include?(__internal_attribute_value__("type")&.downcase(:ascii))

      source = __internal_has_attribute__?("autocorrect") ? self : autocorrect_form_owner
      source.nil? || !source.__internal_attribute_value__("autocorrect").to_s.casecmp?("off")
    end

    def autocorrect=(value)
      __internal_set_attribute_value__("autocorrect", Internal::WebIDL.boolean(value) ? "on" : "off")
    end

    # The form owner an inheriting element takes its hints from, or nil.
    def autocorrect_form_owner
      AUTOCAPITALIZE_INHERITING.include?(local_name) && respond_to?(:form) ? form : nil
    end
    private :autocorrect_form_owner

    js_accessor content_editable: "contentEditable"
    js_readable is_content_editable: "isContentEditable"

    # `contentEditable` (HTML §6.8.1): the attribute's state as a keyword.
    def content_editable
      case Internal::ElementEditing.state(self)
      when :true then "true"
      when :plaintext_only then "plaintext-only"
      when :false then "false"
      else "inherit"
      end
    end

    # "inherit" removes the attribute, "true", "false" and "plaintext-only"
    # (any case) write it in lowercase, and anything else is a SyntaxError.
    def content_editable=(value)
      keyword = value.to_s.downcase(:ascii)
      if keyword == "inherit"
        remove_attribute_ns(nil, "contenteditable")
      elsif %w[true false plaintext-only].include?(keyword)
        __internal_set_attribute_value__("contenteditable", keyword)
      else
        raise DOMException::SyntaxError, "#{value.inspect} is not true, false, plaintext-only or inherit"
      end
    end

    def is_content_editable = Internal::ElementEditing.editable?(self)

    # The state an inherited true / false hint attribute gives this element:
    # true for `on` or "", false for `off`, both matched ASCII
    # case-insensitively; any other value, or none, defers to the parent
    # element, and nil when no ancestor says.
    def inherited_hint(name, on, off)
      node = self
      while node
        case node.__internal_attribute_value__(name)&.downcase(:ascii)
        when on, "" then return true
        when off then return false
        end
        node = node.parent_element
      end
      nil
    end
    private :inherited_hint
    # `dir` reflects its own content attribute, limited to only known values:
    # ltr / rtl / auto in lowercase, "" otherwise. The setter reflects as is;
    # the getter is written here, as HTMLButtonElement#type is. The computed
    # directionality it implies is Internal::Directionality.
    reflect_setter :dir

    def dir = Internal::Directionality.reflected_dir(self)

    # `innerText` / `outerText` (HTML §3.2.7). The getter is the rendered text;
    # the setter replaces the element's children (innerText) or the element
    # itself (outerText) with the value, line breaks becoming <br>.
    def inner_text = Internal::RenderedText::Collector.new(self).text

    def inner_text=(value)
      Internal::RenderedText::Fragment.set_inner(self, value)
    end

    def outer_text = Internal::RenderedText::Collector.new(self).text

    def outer_text=(value)
      Internal::RenderedText::Fragment.set_outer(self, value)
    end

    def __js_get__(key)
      case key
      when "innerText", "outerText" then inner_text
      else super
      end
    end

    def __js_set__(key, value)
      case key
      when "innerText" then self.inner_text = value
      when "outerText" then self.outer_text = value
      else super
      end
    end

    # HTML's form owner ("reset the form owner", steps 3-4). A connected
    # control with a `form` content attribute — the empty string included —
    # belongs to the first element in its own tree whose ID is that value, if
    # that element is a form, and to nothing otherwise; the lookup never reaches
    # out of a shadow tree, or into one. Any other control, a disconnected one
    # included, belongs to its nearest ancestor form.
    #
    # The owner is derived on each read rather than stored, so the "reset"
    # triggers (an ID change, an insertion before the current owner, the owner's
    # removal) are reflected without hooks. The parser's form element pointer,
    # which can associate a control with a form that is not its ancestor, is not
    # modelled.
    def __internal_form_owner__
      return closest("form") unless __internal_has_attribute__?("form") && is_connected?

      form_id = __internal_attribute_value__("form")
      target = get_root_node.get_element_by_id(form_id) unless form_id.empty?
      target if target.is_a?(HTMLFormElement)
    end

    # WHATWG "actually disabled": a form control is disabled if it (or an
    # ancestor <fieldset disabled>) is disabled — EXCEPT a control within that
    # fieldset's first <legend> child is NOT disabled by the fieldset. This drives
    # willValidate / constraint validation (the `:disabled` selector has its own
    # equivalent in SelectorMatcher).
    def disabled_by_ancestor_fieldset?
      node = parent_element
      while node
        if node.local_name.to_s.casecmp?("fieldset") && node.__internal_has_attribute__?("disabled")
          legend = node.children.to_a.find { |c| c.local_name.to_s.casecmp?("legend") }
          return false if legend&.contains?(self)

          return true
        end
        node = node.parent_element
      end
      false
    end

    # `<summary>` has no interface of its own (it is a plain HTMLElement), but it
    # does have activation behavior: clicking the first summary of a <details>
    # toggles the disclosure open or shut.
    def activation_target?
      !__internal_summary_details__.nil?
    end

    def activation_behavior(_event)
      details = __internal_summary_details__
      details.open = !details.open if details
    end

    # The <details> this element is the first <summary> child of, or nil.
    def __internal_summary_details__
      return nil unless local_name.to_s.casecmp?("summary")

      parent = parent_element
      return nil unless parent&.local_name.to_s.casecmp?("details")

      first = parent.children.to_a.find { |c| c.local_name.to_s.casecmp?("summary") }
      first&.equal?(self) ? parent : nil
    end

    # The elements the HTML spec lets a `disabled` content attribute disable.
    DISABLEABLE_LOCAL_NAMES = %w[button input select textarea optgroup option fieldset].freeze

    # WHATWG "actually disabled": one of the disable-able form controls carrying
    # `disabled`, or a control disabled by an ancestor <fieldset disabled>.
    def __internal_actually_disabled__
      return false unless DISABLEABLE_LOCAL_NAMES.include?(local_name.to_s)

      __internal_has_attribute__?("disabled") || disabled_by_ancestor_fieldset?
    end

    # The first element in tree order, in this element's own tree (a
    # document, a shadow root, or a detached subtree), whose ID is `id`.
    def __internal_tree_element_by_id__(id)
      root = get_root_node
      return root.get_element_by_id(id) if root.respond_to?(:get_element_by_id)
      return nil unless root.is_a?(Element)
      return root if root.id == id

      root.query_selector_all("[id]").to_a.find { |el| el.id == id }
    end

    # HTML attribute names are case-insensitive only in an HTML document — the
    # browser DOM lowercases everything there. In a non-HTML (XML) document even an
    # HTML-namespaced element preserves case. Shortcuts Element's namespace check
    # for HTML's hot path while honoring the document-kind condition.
    def case_sensitive_attribute_names?
      !@document.html_document?
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
          c.is_a?(Node) && c.__dommy_backend_node__.equal?(me)
        end
      end
    end

  end

  # `<a>` — exposes URL-component getters/setters via the `href`
  # attribute, plus reflected `target` / `download` / `rel` / `type`.
  # Follow-the-hyperlink activation behavior shared by <a> and <area>. A
  # non-canceled click on a hyperlink (with an href, no download attribute)
  # navigates to its resolved URL: a same-document fragment change fires
  # hashchange and updates :target; anything else is handed to the navigation
  # delegate (which performs the real navigation, or records it by default).

  # `<a>` — exposes URL-component getters/setters via the `href`
  # attribute, plus reflected `target` / `download` / `rel` / `type`.
  # Follow-the-hyperlink activation behavior shared by <a> and <area>. A
  # non-canceled click on a hyperlink (with an href, no download attribute)
  # navigates to its resolved URL: a same-document fragment change fires
  # hashchange and updates :target; anything else is handed to the navigation
  # delegate (which performs the real navigation, or records it by default).
  module HyperlinkActivation
    def activation_target?
      __internal_has_attribute__?("href")
    end

    def activation_behavior(_event)
      return unless __internal_has_attribute__?("href")
      # download turns the click into a save, not a navigation — out of scope.
      return if __internal_has_attribute__?("download")

      target = anchor_href
      win = @document&.default_view
      return if target.to_s.empty? || win.nil? || win.location.nil?

      # A cross-document link hands off to the delegate without pre-mutating the
      # location; a same-document fragment still updates the hash + :target.
      win.location.__internal_navigate_to__(target, source: :link, sync_cross_doc: false)
    end
  end

  # The activation behavior of a submit button: run the owning form's
  # submission algorithm with this button as the submitter. This makes a click
  # — a real user click, a synthesized driver click, or `button.click()` from
  # JS — on a submit button submit its form (fire a SubmitEvent, then hand
  # navigation to the delegate), with no driver-level special-casing. Mirrors
  # HyperlinkActivation for the form side.

  # The activation behavior of a submit button: run the owning form's
  # submission algorithm with this button as the submitter. This makes a click
  # — a real user click, a synthesized driver click, or `button.click()` from
  # JS — on a submit button submit its form (fire a SubmitEvent, then hand
  # navigation to the delegate), with no driver-level special-casing. Mirrors
  # HyperlinkActivation for the form side.
  module SubmitButtonActivation
    def activation_target?
      __internal_submit_button__?
    end

    def activation_behavior(_event)
      return unless __internal_submit_button__?

      # `form` follows the form-owner algorithm (honoring a `form=` attribute) on
      # both input and button, so a form-associated submit button outside its
      # form still submits the right one.
      form&.__internal_run_form_submission__(self)
    end
  end

  # `action` and `formAction` are the two URL attributes HTML marks
  # `[ReflectSetter]`: the setter reflects like any other, but the getter is
  # written out in prose, because a missing or EMPTY attribute reports the
  # document's own address rather than the empty string — a form with no action
  # posts to the page it is on, and `submitter.formAction` says where this button
  # would send it.
  #
  #   "If attribute is null or attribute's value is the empty string, then return
  #    this's node document's URL."
  #
  # https://html.spec.whatwg.org/multipage/form-control-infrastructure.html#dom-fs-action
  module SubmissionUrlAttribute
    private

    def submission_url(name)
      raw = __internal_attribute_value__(name).to_s
      return @document.url.to_s if raw.empty?

      resolve_url(raw)
    end
  end

  # The "Window-reflecting body element event handler set": setting one of these
  # event handler IDL attributes on <body>/<frameset> (`body.onload = fn`)
  # actually targets the WINDOW, per HTML — so `window.onload` fires. A
  # non-reflected handler (`body.onclick`) stays on the element.

  # The "Window-reflecting body element event handler set": setting one of these
  # event handler IDL attributes on <body>/<frameset> (`body.onload = fn`)
  # actually targets the WINDOW, per HTML — so `window.onload` fires. A
  # non-reflected handler (`body.onclick`) stays on the element.
  module WindowReflectingHandlers
    REFLECTED_HANDLERS = %w[
      onblur onerror onfocus onload onresize onscroll onafterprint onbeforeprint
      onbeforeunload onhashchange onlanguagechange onmessage onmessageerror onoffline
      ononline onpagehide onpageshow onpopstate onrejectionhandled onstorage
      onunhandledrejection onunload
    ].to_set.freeze

    def __js_set__(key, value)
      if key.is_a?(String) && REFLECTED_HANDLERS.include?(key) && (win = @document&.default_view)
        return win.__js_set__(key, value)
      end

      super
    end

    def __js_get__(key)
      if key.is_a?(String) && REFLECTED_HANDLERS.include?(key) && (win = @document&.default_view)
        return win.__js_get__(key)
      end

      super
    end
  end

  # The HTMLHyperlinkElementUtils IDL mixin, shared by <a> and <area>. The
  # `href` content attribute, parsed against the document base URL, is the
  # element's URL; every getter reads a component of it and every setter
  # changes that component the way the URL API does, then writes the
  # serialization back into the attribute. Without an href there is no URL
  # and the getters return the empty string (":" for protocol); an href that
  # does not parse reads back as written.
  #
  # Spec: https://html.spec.whatwg.org/multipage/links.html#htmlhyperlinkelementutils

  class HTMLAnchorElement < HTMLElement
    include HyperlinkActivation
    include HyperlinkUtils
    reflect_token_list rel_list: { attr: "rel", js: "relList", supported: Internal::SupportedTokens::HYPERLINK_REL }
    reflect_setter :href
    reflect_enumerated referrer_policy: Internal::EnumeratedKeywordSets::REFERRER_POLICY.merge(attr: "referrerpolicy")

    # `a.text` is an alias for the element's descendant text content.
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

  # `<form>` — element collection, submit/reset, and a stubbed
  # validation surface.

  class HTMLAreaElement < HTMLElement
    include HyperlinkActivation
    include HyperlinkUtils
    reflect_token_list rel_list: { attr: "rel", js: "relList", supported: Internal::SupportedTokens::HYPERLINK_REL }
    reflect_setter :href
    reflect_enumerated referrer_policy: Internal::EnumeratedKeywordSets::REFERRER_POLICY.merge(attr: "referrerpolicy")
  end
end
