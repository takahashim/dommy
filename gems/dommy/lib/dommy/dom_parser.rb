# frozen_string_literal: true

module Dommy
  # `DOMParser` — public-facing parser entry point. Parses an HTML or
  # XML string into a fresh `Dommy::Document`. Per spec, JS code
  # often does:
  #
  #   const doc = new DOMParser().parseFromString(html, "text/html");
  #
  # Supported mime types:
  #   - `text/html`            (full HTML page)
  #   - `application/xhtml+xml`/`application/xml`/`text/xml`/`image/svg+xml`
  #     all delegate to Nokogiri's XML parser
  #
  # The returned Document has no `defaultView` (not attached to a
  # Window). Useful for fragment parsing where you want a Document
  # without spinning up a Window.
  class DOMParser
    # `window` is the browsing context whose script is doing the parsing. A
    # parsed document has no browsing context of its own (`defaultView` is null),
    # but the tasks it queues — a `details` the parser opened owes a toggle event
    # — still run on that window's event loop.
    def initialize(window = nil)
      @window = window
    end

    # `type` is a WebIDL enum (DOMParserSupportedType): matched exactly and
    # case-sensitively, so `"TEXT/HTML"` is a TypeError like any other value
    # outside the enum.
    #
    # Spec: https://html.spec.whatwg.org/#dom-domparser-parsefromstring
    # From script both arguments are required (the JS call checks that); the
    # Ruby API keeps "text/html" as the default it has always had.
    def parse_from_string(string, mime_type = "text/html")
      str = string.to_s
      type = mime_type.is_a?(String) ? mime_type : mime_type.to_s
      doc =
        case type
        when "text/html"
          parse_html(str)
        when "application/xhtml+xml", "application/xml", "text/xml", "image/svg+xml"
          parse_xml(str, type)
        else
          raise Bridge::TypeError, "The provided value '#{type}' is not a valid enum value of type DOMParserSupportedType."
        end
      # The new document's URL and origin are the relevant global object's
      # associated Document's.
      doc.__internal_set_creator__(relevant_document, url: relevant_document&.url)
      doc
    end

    alias parseFromString parse_from_string

    def __js_get__(_key)
      Bridge::ABSENT # method-only; any property read is absent
    end

    include Bridge::Methods
    js_methods %w[parseFromString]
    def __js_call__(method, args)
      case method
      when "parseFromString"
        raise Bridge::TypeError, "parseFromString requires 2 arguments, but only #{args.length} present." if args.length < 2

        parse_from_string(args[0], args[1])
      end
    end

    private

    def parse_html(str)
      backend_doc = Backend.parse(str.empty? ? "<html><body></body></html>" : str)
      doc = Document.new(nil, backend_doc: backend_doc)
      doc.task_scheduler = @window.scheduler if @window.respond_to?(:scheduler)
      doc.__internal_run_parsed_insertion_steps__
      doc.__internal_mark_scripts_already_started__
      doc
    end

    def relevant_document
      @window.respond_to?(:document) ? @window.document : nil
    end

    # Any other type: an XML parser with scripting support disabled. A
    # document that is not well-formed (the empty string included: it has no
    # root element) parses to nothing but a `parsererror` element in the
    # Mozilla parsererror namespace — never an exception.
    def parse_xml(str, mime_type = "application/xml")
      backend_doc =
        begin
          Backend.parse_xml(str)
        rescue ::Makiri::XML::SyntaxError
          nil
        end
      doc = Document.new(nil, backend_doc: backend_doc || Backend.empty_xml_document)
      doc.content_type = mime_type
      if backend_doc
        doc.migrate_xml_template_descendants(backend_doc)
        doc.__internal_mark_scripts_already_started__
      else
        doc.append_child(doc.create_element_ns(PARSERERROR_NAMESPACE, "parsererror"))
      end
      doc
    end

    PARSERERROR_NAMESPACE = "http://www.mozilla.org/newlayout/xml/parsererror.xml"
  end

  # `XMLSerializer` — round-trip a node tree to a string. Used for
  # XML output, SVG inlining, and "serialize this Element" patterns.
  # For HTML, prefer `Element#outer_html` directly.
  class XMLSerializer
    # WHATWG "XML serialization" — produce XML (self-closing empty tags, real XML
    # escaping) rather than the HTML serialization `outer_html` gives. Delegates
    # to the backend's XML serializer (Nokogiri); namespace handling is whatever
    # the backend produces. A Document serializes its root element.
    def serialize_to_string(node)
      return "" unless node

      Internal::XmlSerialization.serialize(node)
    end

    alias serializeToString serialize_to_string

    def __js_get__(_key)
      Bridge::ABSENT # method-only; any property read is absent
    end

    include Bridge::Methods
    js_methods %w[serializeToString]
    def __js_call__(method, args)
      case method
      when "serializeToString"
        serialize_to_string(args[0])
      end
    end
  end
end
