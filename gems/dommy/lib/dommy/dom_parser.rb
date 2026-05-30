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
        parse_xml(str)
      else
        raise DOMException::TypeMismatchError, "Unsupported mime type: #{mime_type}"
      end
    end

    alias parseFromString parse_from_string

    def __js_get__(_key)
      nil
    end

    # Methods routed through __js_call__ (keep in sync with its when-arms).
    JS_METHOD_NAMES = %w[parseFromString].freeze
    def __js_method_names__
      JS_METHOD_NAMES
    end

    def __js_call__(method, args)
      case method
      when "parseFromString"
        parse_from_string(args[0], args[1])
      end
    end

    private

    def parse_html(str)
      nokogiri_doc = Backend.parse(str.empty? ? "<html><body></body></html>" : str)
      Document.new(nil, nokogiri_doc: nokogiri_doc)
    end

    def parse_xml(str)
      # Backends are HTML-only; parse XML input as HTML for now.
      nokogiri_doc = Backend.parse(str.empty? ? "<html><body></body></html>" : str)
      Document.new(nil, nokogiri_doc: nokogiri_doc)
    end
  end

  # `XMLSerializer` — round-trip a node tree to a string. Used for
  # XML output, SVG inlining, and "serialize this Element" patterns.
  # For HTML, prefer `Element#outer_html` directly.
  class XMLSerializer
    def serialize_to_string(node)
      return "" unless node

      if node.respond_to?(:outer_html)
        node.outer_html
      elsif node.respond_to?(:__dommy_backend_node__)
        node.__dommy_backend_node__.to_xml
      elsif node.respond_to?(:to_xml)
        node.to_xml
      else
        node.to_s
      end
    end

    alias serializeToString serialize_to_string

    def __js_get__(_key)
      nil
    end

    # Methods routed through __js_call__ (keep in sync with its when-arms).
    JS_METHOD_NAMES = %w[serializeToString].freeze
    def __js_method_names__
      JS_METHOD_NAMES
    end

    def __js_call__(method, args)
      case method
      when "serializeToString"
        serialize_to_string(args[0])
      end
    end
  end
end
