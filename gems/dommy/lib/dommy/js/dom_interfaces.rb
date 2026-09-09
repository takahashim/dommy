# frozen_string_literal: true

module Dommy
  module Js
    # Derives WebIDL interface metadata for a Dommy DOM object: the most-derived
    # interface name and the single-inheritance chain up to the root
    # (EventTarget for nodes). This mirrors the JS prototype chain the bridge
    # builds so `instanceof` / Object.prototype.toString resolve correctly.
    #
    # Engine-agnostic, and the single home for DOM interface hierarchy knowledge:
    # BASE_CHAINS (seeded eagerly on the JS side) must stay consistent with what
    # #chain_for derives from real objects.
    module DomInterfaces
      # Dommy class basename -> WebIDL interface name, where they diverge.
      # Anything not listed uses the class basename verbatim (HTMLDivElement, …).
      NAME_OVERRIDES = {
        "TextNode" => "Text",
        "CommentNode" => "Comment",
        "ProcessingInstructionNode" => "ProcessingInstruction",
        "CharacterDataNode" => "CharacterData",
        "Fragment" => "DocumentFragment",
        "ClassList" => "DOMTokenList",
        "DatasetMap" => "DOMStringMap",
        "StyleDeclaration" => "CSSStyleDeclaration",
        "LiveNodeList" => "NodeList",
        "StandaloneEventTarget" => "EventTarget"
      }.freeze

      # Concrete HTML element interfaces. A browser exposes every one of these as
      # a global constructor whether or not an instance exists, so a framework's
      # bare `instanceof HTMLInputElement` feature check resolves regardless of
      # page content (idiomorph, Turbo's morph engine, probes `instanceof
      # HTMLInputElement`/`HTMLTextAreaElement` during focus restoration even when
      # the page has no such element). Each is a direct HTMLElement subclass
      # except the two media leaves, appended with their chains below. Mirrors the
      # `class HTMLxxxElement < HTMLElement` set in the dommy gem's html_elements.
      HTML_LEAF_INTERFACES = %w[
        HTMLAnchorElement HTMLAreaElement HTMLBaseElement HTMLBodyElement
        HTMLBRElement HTMLButtonElement HTMLCanvasElement HTMLDataElement HTMLDetailsElement
        HTMLDialogElement HTMLDirectoryElement HTMLDivElement HTMLDListElement
        HTMLDataListElement HTMLEmbedElement HTMLFieldSetElement HTMLFontElement
        HTMLFrameElement HTMLFrameSetElement HTMLParamElement HTMLTableColElement
        HTMLFormElement HTMLHeadElement HTMLHeadingElement HTMLHRElement
        HTMLHtmlElement HTMLIFrameElement HTMLImageElement HTMLInputElement
        HTMLLabelElement HTMLLegendElement HTMLLIElement HTMLLinkElement
        HTMLMapElement HTMLMetaElement HTMLMeterElement HTMLModElement
        HTMLObjectElement HTMLOListElement HTMLOptGroupElement HTMLOptionElement
        HTMLOutputElement HTMLParagraphElement HTMLPictureElement HTMLPreElement
        HTMLProgressElement HTMLQuoteElement HTMLScriptElement HTMLSelectElement
        HTMLSlotElement HTMLSourceElement HTMLSpanElement HTMLStyleElement
        HTMLTableCaptionElement HTMLTableCellElement HTMLTableElement
        HTMLTableRowElement HTMLTableSectionElement HTMLTemplateElement
        HTMLTextAreaElement HTMLTimeElement HTMLTitleElement HTMLTrackElement
        HTMLUListElement
      ].freeze

      # Base interface chains seeded eagerly on the JS side so `instanceof Node`
      # / `typeof HTMLElement` resolve before an instance of that exact type has
      # crossed. Concrete leaves (HTMLButtonElement, …) are built lazily from
      # #chain_for when an instance crosses. Keep consistent with #chain_for.
      BASE_CHAINS = [
        %w[Node EventTarget],
        %w[Element Node EventTarget],
        %w[HTMLElement Element Node EventTarget],
        %w[SVGElement Element Node EventTarget],
        %w[CharacterData Node EventTarget],
        %w[Text CharacterData Node EventTarget],
        %w[Comment CharacterData Node EventTarget],
        %w[ProcessingInstruction CharacterData Node EventTarget],
        %w[Document Node EventTarget],
        %w[DocumentFragment Node EventTarget],
        # ShadowRoot is a DocumentFragment subclass; seeded so bare `node
        # instanceof ShadowRoot` (Alpine.js walks the tree with this) resolves.
        %w[ShadowRoot DocumentFragment Node EventTarget],
        %w[DocumentType Node EventTarget],
        %w[Attr Node EventTarget],
        %w[Event],
        %w[CustomEvent Event],
        %w[MessageEvent Event],
        %w[PopStateEvent Event],
        %w[HashChangeEvent Event],
        %w[SubmitEvent Event],
        %w[CloseEvent Event],
        %w[UIEvent Event],
        %w[MouseEvent UIEvent Event],
        %w[WheelEvent MouseEvent UIEvent Event],
        %w[FocusEvent UIEvent Event],
        %w[KeyboardEvent UIEvent Event],
        %w[CompositionEvent UIEvent Event],
        %w[PromiseRejectionEvent Event],
        %w[ToggleEvent Event],
        %w[ErrorEvent Event],
        %w[DOMException],
        # Window-exposed constructors that frameworks call bare (new X(...)).
        # Seeding them creates the global; construction routes to the window.
        %w[MutationObserver], %w[IntersectionObserver], %w[ResizeObserver],
        %w[PerformanceObserver], %w[AbortController], %w[AbortSignal EventTarget],
        %w[FormData], %w[URL], %w[URLSearchParams], %w[Headers], %w[Request], %w[Response],
        %w[Blob], %w[File Blob], %w[FileList], %w[FileReader EventTarget],
        %w[XMLHttpRequest XMLHttpRequestEventTarget EventTarget],
        %w[XMLHttpRequestEventTarget EventTarget], %w[XMLHttpRequestUpload XMLHttpRequestEventTarget EventTarget],
        %w[TextEncoder], %w[TextDecoder], %w[DOMParser], %w[XMLSerializer],
        %w[MessageChannel], %w[BroadcastChannel EventTarget], %w[WebSocket EventTarget],
        %w[EventSource EventTarget],
        %w[Notification EventTarget], %w[Worker EventTarget], %w[DataTransfer],
        %w[ReadableStream], %w[WritableStream], %w[TransformStream],
        # A Range is an AbstractRange (as a StaticRange would be); Dommy models
        # only the live one, but the base interface still has to exist for
        # `range instanceof AbstractRange`.
        %w[AbstractRange], %w[Range AbstractRange],
        # Web Storage: seeded so `localStorage instanceof Storage` resolves and
        # `Storage.prototype` exists (a global constructor, construction routes
        # to the window / throws like the browser's illegal constructor).
        %w[Storage],
        # CSSOM stylesheet interfaces. Seeded so `style instanceof CSSStyleSheet`
        # resolves: Lit's css-tag runs that check while deciding whether to use
        # constructable stylesheets; with the interface present but
        # `adoptedStyleSheets` unsupported it falls back to injecting a <style>
        # element, which Dommy handles.
        %w[CSSStyleSheet StyleSheet], %w[StyleSheet],
        # CSSOM rule interfaces. Dommy models every rule with one Ruby class
        # carrying a `type`, so the chain a rule reports is derived from that
        # type (see #chain_for) rather than from its Ruby class — but the
        # prototypes still have to exist for `rule instanceof CSSMediaRule`.
        %w[CSSRule], %w[CSSRuleList],
        %w[CSSGroupingRule CSSRule],
        %w[CSSConditionRule CSSGroupingRule CSSRule],
        %w[CSSMediaRule CSSConditionRule CSSGroupingRule CSSRule],
        %w[CSSSupportsRule CSSConditionRule CSSGroupingRule CSSRule],
        %w[CSSStyleRule CSSGroupingRule CSSRule],
        %w[CSSImportRule CSSRule],
        %w[CSSFontFaceRule CSSRule],
        %w[CSSPageRule CSSGroupingRule CSSRule],
        %w[CSSKeyframesRule CSSRule],
        %w[CSSKeyframeRule CSSRule],
        # Collection interfaces, seeded so `result instanceof NodeList` /
        # `instanceof HTMLCollection` resolve (querySelectorAll, children, …).
        %w[NodeList], %w[HTMLCollection], %w[RadioNodeList NodeList],
        %w[HTMLFormControlsCollection HTMLCollection],
        # Traversal: NodeFilter exposes only [Constant]s (NodeFilter.SHOW_ELEMENT,
        # .FILTER_ACCEPT, …); TreeWalker/NodeIterator are instances.
        %w[NodeFilter], %w[TreeWalker], %w[NodeIterator],
        # Concrete HTML element interfaces (see HTML_LEAF_INTERFACES) + the media
        # subtree, so bare `instanceof HTMLInputElement` always resolves.
        *HTML_LEAF_INTERFACES.map { |n| [n, "HTMLElement", "Element", "Node", "EventTarget"] },
        # createElementNS with an unrecognized HTML-namespace local name yields an
        # HTMLUnknownElement; seed it so a bare `instanceof HTMLUnknownElement`
        # resolves even before such an element crosses.
        %w[HTMLUnknownElement HTMLElement Element Node EventTarget],
        %w[HTMLMediaElement HTMLElement Element Node EventTarget],
        %w[HTMLAudioElement HTMLMediaElement HTMLElement Element Node EventTarget],
        %w[HTMLVideoElement HTMLMediaElement HTMLElement Element Node EventTarget]
      ].freeze

      module_function

      # { "name" => most-derived interface, "chain" => [...] } for a host object.
      def info(obj)
        chain = chain_for(obj)
        {"name" => chain.first, "chain" => chain}
      end

      # Walk the Dommy class superclass chain (HTMLDivElement < HTMLElement <
      # Element), then append the module-provided base interfaces (Node ->
      # EventTarget) for nodes, since Dommy models Node as a mixin rather than a
      # superclass. Stops at the first foreign superclass (Object, or
      # StandardError for DOMException) so non-DOM ancestors stay out.
      def chain_for(obj)
        # WHATWG models DOMException as a single interface distinguished by its
        # `name` property — there are no per-name subclasses. Collapse Dommy's
        # convenience subclasses (AbortError < DOMException) to the one interface
        # so a DOMException crossing as a value (e.g. `signal.reason`) reports
        # `constructor === DOMException`, which assert_throws_dom checks.
        return ["DOMException"] if defined?(Dommy::DOMException) && obj.is_a?(Dommy::DOMException)
        # One Ruby class backs every CSS rule, so which CSSOM interface a rule
        # reports comes from its `type` — `@media` is a CSSMediaRule, a style
        # rule is a CSSStyleRule, and so on.
        return css_rule_chain(obj) if defined?(Dommy::CSSRule) && obj.instance_of?(Dommy::CSSRule)

        names = []
        klass = obj.class
        while klass && klass.name&.start_with?("Dommy::")
          name = name_for(klass)
          names << name if name && !names.include?(name)
          klass = klass.superclass
        end
        # WebIDL bases Dommy has no Ruby class for, so the superclass walk above
        # cannot find them.
        IMPLICIT_BASES[names.first]&.each { |base| names << base unless names.include?(base) }
        if defined?(Dommy::Node) && obj.is_a?(Dommy::Node)
          names << "Node" unless names.include?("Node")
          names << "EventTarget" unless names.include?("EventTarget")
        elsif defined?(Dommy::EventTarget) && obj.is_a?(Dommy::EventTarget)
          # Every non-node EventTarget (FileReader, XMLHttpRequest, Worker, …)
          # inherits EventTarget in its IDL too, but Dommy models EventTarget as
          # a mixin rather than a superclass, so append it here.
          names << "EventTarget" unless names.include?("EventTarget")
        end
        names
      end

      # WebIDL base interfaces that sit between a Dommy class and its root but
      # have no Ruby class of their own, keyed by the most-derived interface.
      # Spliced into the chain so `instanceof` matches the IDL hierarchy.
      IMPLICIT_BASES = {
        "Range" => %w[AbstractRange],
        "XMLHttpRequest" => %w[XMLHttpRequestEventTarget],
        "XMLHttpRequestUpload" => %w[XMLHttpRequestEventTarget]
      }.freeze

      # Whether this object's WebIDL interface depends on the instance rather
      # than its Ruby class, so callers must not memoize the answer per class.
      def polymorphic?(value)
        defined?(Dommy::CSSRule) && value.instance_of?(Dommy::CSSRule)
      end

      # The interface chain for a CSS rule, keyed by CSSOM's `CSSRule.type`
      # constant (spelled numerically so this file stays loadable on its own).
      CSS_RULE_CHAINS = {
        1 => %w[CSSStyleRule CSSGroupingRule CSSRule],       # STYLE_RULE
        3 => %w[CSSImportRule CSSRule],                      # IMPORT_RULE
        4 => %w[CSSMediaRule CSSConditionRule CSSGroupingRule CSSRule], # MEDIA_RULE
        5 => %w[CSSFontFaceRule CSSRule],                    # FONT_FACE_RULE
        6 => %w[CSSPageRule CSSGroupingRule CSSRule],        # PAGE_RULE
        7 => %w[CSSKeyframesRule CSSRule],                   # KEYFRAMES_RULE
        8 => %w[CSSKeyframeRule CSSRule],                    # KEYFRAME_RULE
        12 => %w[CSSSupportsRule CSSConditionRule CSSGroupingRule CSSRule] # SUPPORTS_RULE
      }.freeze

      def css_rule_chain(rule)
        CSS_RULE_CHAINS.fetch(rule.type) { %w[CSSRule] }
      end

      def name_for(klass)
        base = klass.name&.split("::")&.last
        return nil unless base

        NAME_OVERRIDES.fetch(base, base)
      end
    end
  end
end
