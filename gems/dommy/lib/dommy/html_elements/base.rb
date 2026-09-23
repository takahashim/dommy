# frozen_string_literal: true

module Dommy
  # The HTMLElement base and the behaviour mixins its subclasses share.
  #
  # One of the HTML element groups; html_elements.rb lists them all.
  # Base for specialized HTMLElement subclasses. Inherits reflection
  # helpers from Internal::ReflectedAttributes (also shared with
  # SVGElement).
  class HTMLElement < Element
    include Internal::ReflectedAttributes

    # HTML's form owner. A `form` content attribute names a form BY ID IN THIS
    # ELEMENT'S OWN TREE — the association never reaches out of a shadow tree,
    # or into one — and with no such attribute the owner is the nearest ancestor
    # form.
    def __internal_form_owner__
      form_id = get_attribute("form").to_s
      return closest("form") if form_id.empty?

      root = get_root_node
      target = root.get_element_by_id(form_id) if root.respond_to?(:get_element_by_id)
      target if target.respond_to?(:tag_name) && target.tag_name.to_s.casecmp?("form")
    end

    # WHATWG "actually disabled": a form control is disabled if it (or an
    # ancestor <fieldset disabled>) is disabled — EXCEPT a control within that
    # fieldset's first <legend> child is NOT disabled by the fieldset. This drives
    # willValidate / constraint validation (the `:disabled` selector has its own
    # equivalent in SelectorMatcher).
    def disabled_by_ancestor_fieldset?
      node = parent_element
      while node
        if node.local_name.to_s.casecmp?("fieldset") && node.has_attribute?("disabled")
          legend = node.child_nodes.to_a.find do |c|
            c.respond_to?(:local_name) && c.local_name.to_s.casecmp?("legend")
          end
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
      return nil unless parent.respond_to?(:local_name) && parent.local_name.to_s.casecmp?("details")

      first = parent.children.to_a.find { |c| c.local_name.to_s.casecmp?("summary") }
      first&.equal?(self) ? parent : nil
    end

    # The elements the HTML spec lets a `disabled` content attribute disable.
    DISABLEABLE_LOCAL_NAMES = %w[button input select textarea optgroup option fieldset].freeze

    # WHATWG "actually disabled": one of the disable-able form controls carrying
    # `disabled`, or a control disabled by an ancestor <fieldset disabled>.
    def __internal_actually_disabled__
      return false unless DISABLEABLE_LOCAL_NAMES.include?(local_name.to_s)

      has_attribute?("disabled") || disabled_by_ancestor_fieldset?
    end

    # Shared "limited to only non-negative numbers" long reflection (maxLength /
    # minLength on input and textarea): a missing / negative / non-numeric
    # content attribute reads as -1; assigning a negative value throws.
    def parse_non_negative_reflected(attr)
      raw = @__node__[attr]
      return -1 if raw.nil?
      # HTML "rules for parsing non-negative integers": leading ASCII whitespace,
      # then digits; anything else (a sign, letters) is an error → -1.
      m = raw.to_s.match(/\A[\t\n\f\r ]*(\d+)/)
      m ? m[1].to_i : -1
    end

    def set_non_negative_reflected(attr, value)
      n = value.to_i
      raise DOMException::IndexSizeError, "#{attr} must be non-negative" if n.negative?

      set_reflected_string(attr, n.to_s)
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
      __submit_button__?
    end

    def activation_behavior(_event)
      return unless __submit_button__?

      # `form` follows the form-owner algorithm (honoring a `form=` attribute) on
      # both input and button, so a form-associated submit button outside its
      # form still submits the right one.
      form&.__run_form_submission__(self)
    end
  end

  # `formAction` is a URL-reflecting IDL attribute on the submit buttons that
  # carry it: the setter writes the content attribute verbatim, and the getter
  # resolves it against the document base URL — falling back to the document's
  # own address when the attribute is missing or empty, so a submit button
  # without a `formaction` reports where the form would post.

  # `formAction` is a URL-reflecting IDL attribute on the submit buttons that
  # carry it: the setter writes the content attribute verbatim, and the getter
  # resolves it against the document base URL — falling back to the document's
  # own address when the attribute is missing or empty, so a submit button
  # without a `formaction` reports where the form would post.
  module FormActionUrl
    def form_action
      raw = get_attribute("formaction").to_s
      return @document.url.to_s if raw.empty?

      resolve_url(raw)
    end

    def form_action=(value)
      set_attribute("formaction", value.to_s)
    end

    def __js_get__(key)
      key == "formAction" ? form_action : super
    end

    def __js_set__(key, value)
      key == "formAction" ? (self.form_action = value) : super
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
    reflect_string :target, :download, :rel, :hreflang, :type

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
    reflect_string :alt, :coords, :shape, :target, :rel
  end
end
