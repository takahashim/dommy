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
        # LiveList is the shared implementation base of LiveNodeList and
        # StyleSheetList, not an interface of its own: nil keeps it out of the
        # chain so a StyleSheetList reports [StyleSheetList], not
        # [StyleSheetList, LiveList].
        "LiveList" => nil,
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
        HTMLMapElement HTMLMarqueeElement HTMLMenuElement HTMLMetaElement HTMLMeterElement HTMLModElement
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
        %w[MathMLElement Element Node EventTarget],
        %w[CharacterData Node EventTarget],
        %w[Text CharacterData Node EventTarget],
        %w[Comment CharacterData Node EventTarget],
        %w[ProcessingInstruction CharacterData Node EventTarget],
        %w[Document Node EventTarget],
        # HTMLDocument is the legacy alias an HTML document reports as its
        # most-derived interface (`document.constructor === HTMLDocument`).
        %w[HTMLDocument Document Node EventTarget],
        # XMLDocument is what `implementation.createDocument` returns; a
        # DOMParser/XML-parsed document reports the base `Document` instead, so
        # the two are distinguished by a flag, not by content type.
        %w[XMLDocument Document Node EventTarget],
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
        %w[PageTransitionEvent Event],
        %w[HashChangeEvent Event],
        %w[SubmitEvent Event],
        %w[FormDataEvent Event],
        %w[CloseEvent Event],
        %w[UIEvent Event],
        %w[MouseEvent UIEvent Event],
        %w[WheelEvent MouseEvent UIEvent Event],
        %w[FocusEvent UIEvent Event],
        %w[KeyboardEvent UIEvent Event],
        %w[CompositionEvent UIEvent Event],
        %w[PromiseRejectionEvent Event],
        %w[ToggleEvent Event],
        %w[CommandEvent Event],
        %w[ErrorEvent Event],
        %w[DOMException], %w[DOMImplementation],
        # Window-exposed constructors that frameworks call bare (new X(...)).
        # Seeding them creates the global; construction routes to the window.
        %w[MutationObserver], %w[IntersectionObserver], %w[ResizeObserver],
        %w[PerformanceObserver], %w[AbortController], %w[AbortSignal EventTarget],
        %w[FormData], %w[URL], %w[URLSearchParams], %w[Headers], %w[Request], %w[Response],
        %w[Blob], %w[File Blob], %w[FileList], %w[DOMStringList], %w[FileReader EventTarget],
        %w[XMLHttpRequest XMLHttpRequestEventTarget EventTarget],
        %w[XMLHttpRequestEventTarget EventTarget], %w[XMLHttpRequestUpload XMLHttpRequestEventTarget EventTarget],
        %w[TextEncoder], %w[TextDecoder], %w[DOMParser], %w[XMLSerializer],
        %w[MessageChannel], %w[BroadcastChannel EventTarget], %w[WebSocket EventTarget],
        %w[EventSource EventTarget],
        %w[Notification EventTarget], %w[Worker EventTarget], %w[DataTransfer],
        %w[ReadableStream], %w[WritableStream], %w[TransformStream],
        %w[CountQueuingStrategy], %w[ByteLengthQueuingStrategy],
        %w[URLPattern],
        %w[TextEncoderStream], %w[TextDecoderStream], %w[CompressionStream], %w[DecompressionStream],
        %w[Animation EventTarget], %w[AnimationEffect], %w[KeyframeEffect AnimationEffect],
        %w[Touch], %w[TouchEvent UIEvent Event],
        %w[PointerEvent MouseEvent UIEvent Event], %w[DragEvent MouseEvent UIEvent Event],
        %w[InputEvent UIEvent Event], %w[ClipboardEvent Event], %w[BeforeUnloadEvent Event],
        %w[ProgressEvent Event],
        %w[StorageEvent Event], %w[TextEvent UIEvent Event],
        %w[DeviceMotionEvent Event], %w[DeviceOrientationEvent Event],
        # Range and StaticRange are both AbstractRanges. The base interface has
        # no Ruby class, but it still has to exist for `instanceof AbstractRange`.
        %w[AbstractRange], %w[Range AbstractRange], %w[StaticRange AbstractRange],
        # Seeded so `getSelection() instanceof Selection` resolves.
        %w[Selection],
        # Web Storage: seeded so `localStorage instanceof Storage` resolves and
        # `Storage.prototype` exists (a global constructor, construction routes
        # to the window / throws like the browser's illegal constructor).
        %w[Storage],
        # CSSOM stylesheet interfaces. `CSSStyleSheet` is constructable for
        # component bundles that prepare CSS with `new CSSStyleSheet()`;
        # adoptedStyleSheets remains unsupported.
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
        %w[NodeList], %w[HTMLCollection], %w[RadioNodeList NodeList], %w[DOMTokenList],
        %w[HTMLFormControlsCollection HTMLCollection],
        # StyleSheetList is an indexed-getter collection with no iterable<>:
        # seeded so `document.styleSheets instanceof StyleSheetList` resolves.
        %w[StyleSheetList],
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

        names = class_chain(obj.class).dup
        # An HTML document reports as an HTMLDocument — the legacy alias browsers
        # expose — so `document.constructor === HTMLDocument` and
        # `document.__proto__ === HTMLDocument.prototype` hold.
        if names.first == "Document"
          if obj.respond_to?(:html_document?) && obj.html_document?
            names.unshift("HTMLDocument")
          elsif obj.respond_to?(:xml_document?) && obj.xml_document?
            names.unshift("XMLDocument")
          end
        end
        names
      end

      # The interface chain every instance of `klass` shares: the Dommy class
      # superclass walk, the IDL bases Dommy has no class for, and Node /
      # EventTarget, which Dommy models as mixins. (#chain_for adds what depends
      # on the instance.)
      def class_chain(klass)
        names = []
        k = klass
        # A custom element's class is the page's own — an anonymous subclass
        # for a JS-defined element (BridgedCustomElement's per-name subclass),
        # or a Ruby app's class — and is no interface: the element reports the
        # interface it derives from (HTMLElement), as `Object.prototype
        # .toString` and the prototype members' receiver checks expect.
        k = k.superclass while k && !interface_class?(k)
        while k && k.name&.start_with?("Dommy::")
          name = name_for(k)
          names << name if name && !names.include?(name)
          k = k.superclass
        end
        # WebIDL bases Dommy has no Ruby class for, so the superclass walk above
        # cannot find them.
        IMPLICIT_BASES[names.first]&.each { |base| names << base unless names.include?(base) }
        if defined?(Dommy::Node) && klass <= Dommy::Node
          names << "Node" unless names.include?("Node")
          names << "EventTarget" unless names.include?("EventTarget")
        elsif defined?(Dommy::EventTarget) && klass <= Dommy::EventTarget
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
        "StaticRange" => %w[AbstractRange],
        "KeyframeEffect" => %w[AnimationEffect],
        "XMLHttpRequest" => %w[XMLHttpRequestEventTarget],
        "XMLHttpRequestUpload" => %w[XMLHttpRequestEventTarget]
      }.freeze

      # Whether this object's WebIDL interface depends on the instance rather
      # than its Ruby class, so callers must not memoize the answer per class.
      # A CSS rule's interface comes from its `type`; a Document's is
      # HTMLDocument / XMLDocument / Document, decided per instance.
      def polymorphic?(value)
        (defined?(Dommy::CSSRule) && value.instance_of?(Dommy::CSSRule)) ||
          (defined?(Dommy::Document) && value.is_a?(Dommy::Document))
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

      def interface_class?(klass)
        name = klass.name
        name&.start_with?("Dommy::") && name != "Dommy::Js::BridgedCustomElement"
      end

      def name_for(klass)
        base = klass.name&.split("::")&.last
        return nil unless base

        NAME_OVERRIDES.fetch(base, base)
      end
    end
  end
end
