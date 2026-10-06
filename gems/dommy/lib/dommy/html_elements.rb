# frozen_string_literal: true

require "date"
require "set"

require_relative "validity_state"
require_relative "html_elements/base"
require_relative "html_elements/forms"
require_relative "html_elements/tables"
require_relative "html_elements/media"
require_relative "html_elements/embedded"
require_relative "html_elements/metadata"
require_relative "html_elements/interactive"
require_relative "html_elements/miscellaneous"

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
    "menu" => HTMLMenuElement,
    "marquee" => HTMLMarqueeElement,
    "dl" => HTMLDListElement,
    "font" => HTMLFontElement,
    "frame" => HTMLFrameElement,
    "frameset" => HTMLFrameSetElement,
    "param" => HTMLParamElement,
    # HTML "element interface": listing and xmp are HTMLPreElement.
    "listing" => HTMLPreElement,
    "xmp" => HTMLPreElement
  }.freeze

  # HTML "element interface" (https://html.spec.whatwg.org/#element-interface):
  # the names whose interface is plain HTMLElement — the elements this
  # specification defines with no interface of their own, plus the obsolete
  # ones it lists (acronym … tt) — and the obsolete names that are
  # HTMLUnknownElement whatever else applies.
  HTML_ELEMENT_NAMES_WITH_NO_OWN_INTERFACE = %w[
    abbr address article aside b bdi bdo cite code dd dfn dt em figcaption
    figure footer header hgroup i kbd main mark nav noscript rp rt ruby s samp
    search section small strong sub summary sup u var wbr
    acronym basefont big center nobr noembed noframes plaintext rb rtc strike tt
  ].to_set.freeze
  HTML_UNKNOWN_ELEMENT_NAMES = %w[applet bgsound blink isindex keygen multicol nextid spacer].to_set.freeze

  SVG_NAMESPACE_URI = Internal::Namespaces::SVG
  HTML_NAMESPACE_URI = Internal::Namespaces::HTML

  # The interface for an HTML-namespace element whose local name maps to no
  # specialized interface (e.g. createElementNS with an upper-case or otherwise
  # unrecognized name). Still an HTMLElement, so `instanceof HTMLElement` holds.
  class HTMLUnknownElement < HTMLElement
  end

  # Map a (local name, namespace) pair to its DOM interface class. HTML-namespace
  # names match case-SENSITIVELY (createElement lower-cases first, but
  # createElementNS preserves case, so "SPAN" is unknown); a MathML element is
  # a MathMLElement, and any other namespace — including the null namespace —
  # gets the generic Element.
  def self.element_class_for(tag_name, namespace_uri = nil)
    name = tag_name.to_s
    case namespace_uri
    when SVG_NAMESPACE_URI
      SVG_ELEMENT_CLASSES[name.downcase] || SVGElement
    when Internal::Namespaces::MATHML
      MathMLElement
    when HTML_NAMESPACE_URI
      # An unrecognized name that is a *valid custom element name* is an
      # undefined custom element, and its interface is HTMLElement — only a
      # genuinely unknown name falls through to HTMLUnknownElement.
      return HTMLUnknownElement if HTML_UNKNOWN_ELEMENT_NAMES.include?(name)
      return HTMLElement if HTML_ELEMENT_NAMES_WITH_NO_OWN_INTERFACE.include?(name)

      HTML_ELEMENT_CLASSES[name] ||
        (CustomElementRegistry.valid_name?(name) ? HTMLElement : HTMLUnknownElement)
    else
      Element
    end
  end
end
