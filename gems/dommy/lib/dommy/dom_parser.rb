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
    def parse_from_string(string, mime_type = "text/html")
      str = string.to_s
      case mime_type.to_s.downcase
      when "text/html", ""
        parse_html(str)
      when "application/xhtml+xml", "application/xml", "text/xml", "image/svg+xml"
        parse_xml(str, mime_type.to_s.downcase)
      else
        # `type` is a WebIDL enum (DOMParserSupportedType); an out-of-enum value
        # is a TypeError, not a DOMException.
        raise Bridge::TypeError, "The provided value '#{mime_type}' is not a valid enum value of type DOMParserSupportedType."
      end
    end

    alias parseFromString parse_from_string

    def __js_get__(_key)
      nil
    end

    include Bridge::Methods
    js_methods %w[parseFromString]
    def __js_call__(method, args)
      case method
      when "parseFromString"
        parse_from_string(args[0], args[1])
      end
    end

    private

    def parse_html(str)
      backend_doc = Backend.parse(str.empty? ? "<html><body></body></html>" : str)
      Document.new(nil, backend_doc: backend_doc)
    end

    def parse_xml(str, mime_type = "application/xml")
      backend_doc = Backend.parse_xml(str.empty? ? "<root/>" : str)
      doc = Document.new(nil, backend_doc: backend_doc)
      doc.content_type = mime_type
      doc
    end
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
      nil
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
