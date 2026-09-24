# frozen_string_literal: true

module Dommy
  # The document's own metadata and the resources it pulls in.
  #
  # One of the HTML element groups; html_elements.rb lists them all.
  # `<script>` — `src` / `type` / `async` / `defer` / `text`.
  class HTMLScriptElement < HTMLElement
    reflect_url :src
    reflect_string :type, :integrity, :nonce, referrer_policy: "referrerpolicy",
                   html_for: { attr: "for", js: "htmlFor" }
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

      # Whether the script is external is whether it HAS a src attribute; what to
      # fetch is the IDL `src`, which resolves it against the document.
      if get_attribute("src").nil?
        body = text_content.to_s
        return nil if body.strip.empty?

        @__script_started = true
        [:inline, body]
      else
        @__script_started = true
        [:external, src]
      end
    end
  end

  # `<link>` — primarily for stylesheets, icons, preload, manifests.

  # `<link>` — primarily for stylesheets, icons, preload, manifests.
  class HTMLLinkElement < HTMLElement
    reflect_boolean :disabled
    reflect_url :href
    reflect_token_list :sizes, rel_list: { attr: "rel", js: "relList" }
    reflect_string :rel, :type, :media, :hreflang, :integrity, as_attr: { attr: "as", js: "as" }, crossorigin: { js: "crossOrigin" }, referrer_policy: "referrerpolicy"
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

  class HTMLStyleElement < HTMLElement
    reflect_string :type, :media
    def disabled
      @__disabled == true
    end

    def disabled=(v)
      @__disabled = !!v
    end

    # `style.sheet` — the CSSOM sheet, which exists only while the element is
    # browsing-context connected: a `<style>` built in script, or one inside a
    # shadow tree whose host is not in the document, has no sheet yet. Memoized
    # per text content (CSSOM: repeated reads return the same object), seeded
    # with the element's CSS text so insertRule/deleteRule order against it.
    # Rewriting the element's text discards the sheet and any rules inserted via
    # CSSOM — browsers re-parse into a fresh sheet too.
    def sheet
      return nil unless is_connected?

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

    js_accessor :disabled
    js_readable :sheet

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

  class HTMLBaseElement < HTMLElement
    reflect_setter :href
    reflect_string :target

    # A `<base>` is what gives the document its base URL, so its own `href`
    # cannot resolve against that: HTML resolves it against the document's
    # FALLBACK base URL — the address the document would have with no <base> at
    # all — and returns the attribute verbatim when that fails.
    # https://html.spec.whatwg.org/multipage/semantics.html#dom-base-href
    def href
      raw = get_attribute("href").to_s
      fallback = @document.url.to_s
      return raw if fallback.empty?

      Internal::UrlParser.serialize(Internal::UrlParser.parse(raw, fallback))
    rescue Internal::UrlParser::Failure
      raw
    end
  end

  class HTMLMetaElement < HTMLElement
    reflect_string :name, :content, :charset, http_equiv: "http-equiv"
  end

  class HTMLHtmlElement < HTMLElement
  end
  class HTMLHeadElement < HTMLElement
  end

  class HTMLBodyElement < HTMLElement
    include WindowReflectingHandlers
  end
end
