# frozen_string_literal: true

require_relative "../internal/element_tasks"

module Dommy
  # The document's own metadata and the resources it pulls in.
  #
  # One of the HTML element groups; html_elements.rb lists them all.
  # `<script>` — `src` / `type` / `async` / `defer` / `text`.
  class HTMLScriptElement < HTMLElement
    include Internal::ElementTasks
    reflect_url :src
    reflect_string :type, :integrity, html_for: { attr: "for", js: "htmlFor" }
    reflect_enumerated referrer_policy: Internal::EnumeratedKeywordSets::REFERRER_POLICY.merge(attr: "referrerpolicy"),
                       crossorigin: Internal::EnumeratedKeywordSets::CROSS_ORIGIN.merge(js: "crossOrigin"),
                       fetch_priority: Internal::EnumeratedKeywordSets::FETCH_PRIORITY
    reflect_boolean :defer, no_module: "nomodule"
    reflect_token_list blocking: { supported: Internal::SupportedTokens::BLOCKING }
    # `text` is an alias for textContent on <script>.
    def text
      text_content
    end

    def text=(v)
      self.text_content = v
    end

    # HTML's "force async" flag (scripting.html §4.12.1.1): true from the
    # moment a script element exists — `document.createElement("script")`,
    # `cloneNode()` — until something proves it is not meant to run in parse
    # order. Cleared by: the HTML/XML parser inserting the element
    # (`__internal_mark_parser_inserted__`, called for the initial document
    # parse and for every parser/fragment-parsed script — see
    # Document#__internal_run_parsed_insertion_steps__ and
    # Element#mark_fragment_scripts_started), the `async` IDL setter
    # (unconditionally), and the `async` content attribute being ADDED
    # (`__internal_attribute_changed__` below). `nil` is the unset default,
    # standing for HTML's "initially true".
    def async
      force_async = @__force_async.nil? ? true : @__force_async
      force_async || reflected_boolean("async")
    end

    def async=(value)
      @__force_async = false
      set_reflected_boolean("async", value)
    end

    # The HTML/XML parser's own insertion step for a script element it
    # creates: clears force async immediately, well before "prepare the
    # script" ever runs. Dommy's parser builds the tree natively, without
    # running per-element Ruby insertion steps, so the initial document parse
    # and fragment parsing (innerHTML / outerHTML / insertAdjacentHTML) call
    # this by hand for every <script> the parse produced.
    def __internal_mark_parser_inserted__
      @__force_async = false
      nil
    end

    # The parser document a document's own parse gives the scripts it
    # inserted: the post-connection steps leave such a script to the parser
    # (script boot). Only the document parse sets it — a script the parser put
    # in a template's contents runs when the contents are moved into the
    # document, as Chromium does.
    def __internal_mark_parser_document__
      @__parser_inserted = true
      nil
    end

    # HTML's attribute change steps for `async`: ADDING the content attribute
    # clears force async, independent of (and in addition to) the IDL setter.
    def __internal_attribute_changed__(name, old_value, _new_value, namespace)
      super
      @__force_async = false if namespace.nil? && old_value.nil? && name.casecmp?("async")
    end

    js_accessor :async

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

    # MIME Sniffing's JavaScript MIME type essences: a script block's type
    # string that is an ASCII case-insensitive match for one of these makes the
    # script classic.
    JAVASCRIPT_MIME_TYPE_ESSENCES = %w[
      application/ecmascript application/javascript application/x-ecmascript
      application/x-javascript text/ecmascript text/javascript text/javascript1.0
      text/javascript1.1 text/javascript1.2 text/javascript1.3 text/javascript1.4
      text/javascript1.5 text/jscript text/livescript text/x-ecmascript text/x-javascript
    ].freeze

    ASCII_WHITESPACE_EDGES = /\A[\t\n\f\r ]+|[\t\n\f\r ]+\z/

    # What "prepare the script element" decided to run: the script's type
    # (:classic, :module, :importmap, :speculationrules), whether it comes from
    # an external file, and either its source text (inline) or the URL to
    # fetch (external).
    PreparedScript = Struct.new(:type, :external, :source, :url, keyword_init: true)

    # The script types `HTMLScriptElement.supports(type)` answers true for —
    # matched exactly, not ASCII case-insensitively and not as MIME types.
    SUPPORTED_SCRIPT_TYPES = %w[classic module importmap speculationrules].freeze

    def self.supports(type) = SUPPORTED_SCRIPT_TYPES.include?(type.to_s)

    def self.javascript_mime_type_essence_match?(string)
      JAVASCRIPT_MIME_TYPE_ESSENCES.include?(string.to_s.downcase(:ascii))
    end

    # The type "prepare the script element" gives this script (its steps on
    # the `type` and `language` attributes): :classic for every JavaScript MIME
    # type essence match, :module, :importmap or :speculationrules for those
    # keywords, and nil for anything else — a JSON block, a template type —
    # which never runs.
    def __internal_script_type__
      type_attr = __internal_attribute_value__("type")
      language = __internal_attribute_value__("language")
      type_string =
        if type_attr == "" || (type_attr.nil? && language.to_s.empty?)
          "text/javascript"
        elsif type_attr
          type_attr
        else
          "text/#{language}"
        end
      if self.class.javascript_mime_type_essence_match?(type_string) ||
         (type_attr && self.class.javascript_mime_type_essence_match?(type_attr.gsub(ASCII_WHITESPACE_EDGES, "")))
        return :classic
      end

      case type_string.downcase(:ascii)
      when "module" then :module
      when "importmap" then :importmap
      when "speculationrules" then :speculationrules
      end
    end

    # Set the HTML "already started" flag without running anything. The fragment
    # parsing algorithm (innerHTML / insertAdjacentHTML / outerHTML / DOMParser)
    # flags its scripts this way so they never execute on insertion.
    def __internal_mark_script_already_started__
      @__script_started = true
      nil
    end

    def __internal_script_already_started__ = @__script_started == true

    # Whether the element is parser-inserted (has a parser document): the
    # script post-connection steps leave such a script to the parser.
    def __internal_parser_inserted__ = @__parser_inserted == true

    # HTML's cloning steps for a script: the copy's "already started" is the
    # original's, so cloning a parsed-but-inert script (DOMParser, innerHTML)
    # does not make a copy that runs on insertion.
    def __internal_cloning_state__
      merge_cloning_state(super, @__script_started ? {already_started: true} : {})
    end

    def __internal_apply_cloning_state__(state)
      super
      @__script_started = true if state[:already_started]
    end

    # HTML "prepare the script element", up to where the work splits by type:
    # returns a PreparedScript to fetch / run, or nil when nothing runs. The
    # caller (script boot for a parser-inserted script, the post-connection
    # steps for any other) does the fetching and the executing, which needs a
    # JS engine.
    #
    # Order matters, as the spec writes it: a script with no `src` and an
    # EMPTY body (whitespace is not empty) returns BEFORE "already started" is
    # set, so a later child or `src` change can still run it; an unknown type
    # returns before it too. Everything after — `nomodule`, the `event`/`for`
    # legacy, a bad `src` — has already started the script.
    def __internal_prepare_script__
      return nil if @__script_started

      parser_inserted = @__parser_inserted
      @__parser_inserted = false
      @__force_async = true if parser_inserted && __internal_attribute_value__("async").nil?
      source = Backend.child_text_content(@__node__).to_s
      src = __internal_attribute_value__("src")
      return nil if src.nil? && source.empty?
      return nil unless is_connected?

      type = __internal_script_type__
      return nil unless type

      if parser_inserted
        @__parser_inserted = true
        @__force_async = false
      end
      @__script_started = true
      return nil if type == :classic && !__internal_attribute_value__("nomodule").nil?
      return nil if type == :classic && !window_onload_event_for?

      return @__internal_prepared_script__ = PreparedScript.new(type: type, external: false, source: source) if src.nil?

      prepare_external(type, src)
    end

    # The PreparedScript of the last preparation that produced one: lets a
    # host that is handed only the element (an external-script runner) tell a
    # module from a classic script.
    attr_reader :__internal_prepared_script__

    private

    # "If el has a src content attribute": external import maps and
    # speculation rules are not supported, and an empty or unparsable src
    # fails; each failure is an `error` event queued at the element.
    def prepare_external(type, src)
      return queue_script_error_event if %i[importmap speculationrules].include?(type) || src.empty?

      base = @document.base_uri.to_s
      url = Internal::UrlParser.serialize(
        Internal::UrlParser.parse(src, base.empty? ? nil : base, encoding: @document.character_encoding)
      )
      @__internal_prepared_script__ = PreparedScript.new(type: type, external: true, url: url)
    rescue Internal::UrlParser::Failure
      queue_script_error_event
    end

    def queue_script_error_event
      queue_element_task { __internal_fire_event__("error") }
      nil
    end

    # The legacy `<script event="onload" for="window">` form: a classic script
    # with both attributes runs only when they name the window's load event.
    def window_onload_event_for?
      event = __internal_attribute_value__("event")
      for_attr = __internal_attribute_value__("for")
      return true if event.nil? || for_attr.nil?

      for_attr.gsub(ASCII_WHITESPACE_EDGES, "").casecmp?("window") &&
        %w[onload onload()].any? { |name| event.gsub(ASCII_WHITESPACE_EDGES, "").casecmp?(name) }
    end

    public

    # Compatibility shims over #__internal_prepare_script__ for the three
    # kinds of runnable script: each prepares the script only when it is of
    # its kind, so asking for the wrong kind leaves it unstarted.
    def __internal_take_pending_script__
      prepared = prepare_if { |type, external| type == :classic && !external }
      prepared&.source
    end

    def __internal_take_pending_src__
      prepared = prepare_if { |type, external| type == :classic && external }
      prepared&.url
    end

    def __internal_take_pending_module__
      prepared = prepare_if { |type, _external| type == :module }
      return nil unless prepared

      prepared.external ? [:external, prepared.url] : [:inline, prepared.source]
    end

    private

    def prepare_if
      return nil unless yield(__internal_script_type__, !__internal_attribute_value__("src").nil?)

      __internal_prepare_script__
    end

    public
  end

  # `<link>` — primarily for stylesheets, icons, preload, manifests.

  # `<link>` — primarily for stylesheets, icons, preload, manifests.
  class HTMLLinkElement < HTMLElement
    reflect_boolean :disabled
    reflect_url :href
    reflect_token_list :sizes, rel_list: { attr: "rel", js: "relList", supported: Internal::SupportedTokens::LINK_REL },
                              blocking: { supported: Internal::SupportedTokens::BLOCKING }
    reflect_string :rel, :type, :media, :hreflang, :integrity
    # The `as` attribute is an enumerated attribute whose keywords are "each of
    # the union of preload destinations and module preload destinations"
    # (semantics.html, the link element), and the IDL attribute reflects it
    # limited to only known values, with no missing or invalid value default.
    # A preload destination is fetch, font, image, script, style or track
    # (links.html, rel=preload); a module preload destination is json, style,
    # text or a Fetch script-like destination: audioworklet, paintworklet,
    # script, serviceworker, sharedworker, worker (rel=modulepreload).
    #
    # This is deliberately NOT Fetch's list of potential destinations, which
    # the spec used before and WPT's html/dom/elements-metadata.js still
    # expects: audio, document, embed, manifest, object, report, video and
    # xslt name no state now, so `link.as` reads "" for them.
    AS_KEYWORDS = %w[
      fetch font image script style track json text audioworklet paintworklet
      serviceworker sharedworker worker
    ].freeze
    reflect_enumerated as_attr: { attr: "as", js: "as", keywords: AS_KEYWORDS, missing: nil, invalid: nil },
                       crossorigin: Internal::EnumeratedKeywordSets::CROSS_ORIGIN.merge(js: "crossOrigin"),
                       referrer_policy: Internal::EnumeratedKeywordSets::REFERRER_POLICY.merge(attr: "referrerpolicy"),
                       fetch_priority: Internal::EnumeratedKeywordSets::FETCH_PRIORITY
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
        title: __internal_attribute_value__("title").to_s,
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
    reflect_token_list blocking: { supported: Internal::SupportedTokens::BLOCKING }
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
        title: __internal_attribute_value__("title").to_s,
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
    # The child text content: a descendant element's text is no part of it.
    def text
      Backend.child_text_content(@__node__)
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
      raw = __internal_attribute_value__("href").to_s
      fallback = @document.url.to_s
      return raw if fallback.empty?

      Internal::UrlParser.serialize(Internal::UrlParser.parse(raw, fallback))
    rescue Internal::UrlParser::Failure
      raw
    end
  end

  class HTMLMetaElement < HTMLElement
    # The IDL reflects no `charset`: the attribute is read by the encoding
    # sniffing, not exposed.
    reflect_string :name, :content, :media, :scheme, http_equiv: "http-equiv"

    # HTML's pragma directives run "when a meta element is inserted into the
    # document" (and only then: a later change to its attributes, or removing
    # it, does nothing). The one dommy acts on is the Content language state,
    # which sets the document's pragma-set default language — the fallback
    # language of a node no `lang` attribute covers.
    def __internal_run_pragma__
      return unless http_equiv.casecmp?("content-language")
      return unless get_root_node.equal?(@document)

      language = content_language_pragma_value
      @document.__internal_pragma_default_language__ = language if language
    end

    private

    # The Content language state's steps: no content attribute, or one with a
    # comma, sets nothing; else the first run of non-whitespace after leading
    # ASCII whitespace, unless that is empty.
    def content_language_pragma_value
      input = __internal_attribute_value__("content")
      return nil if input.nil? || input.include?(",")

      candidate = input.sub(/\A[ \t\n\f\r]+/, "")[/\A[^ \t\n\f\r]*/]
      candidate unless candidate.empty?
    end
  end

  class HTMLHtmlElement < HTMLElement
  end
  class HTMLHeadElement < HTMLElement
  end

  class HTMLBodyElement < HTMLElement
    include WindowReflectingHandlers
  end
end
