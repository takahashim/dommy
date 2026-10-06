# frozen_string_literal: true

require_relative "url_parser"

module Dommy
  module Internal
    # The pieces of HTML's navigables that an `<iframe>`'s child navigable needs
    # and that are not the element's own business: what URL "matches
    # about:blank", the document a navigation response becomes, and the
    # delegate a child navigable's own navigations go through.
    #
    # Dommy fetches nothing itself. A child navigable's navigation to a network
    # URL is handed to the embedder through the parent window's navigation
    # delegate (its optional `load_frame`), and only about:blank, about:srcdoc,
    # data: and blob: documents are made here.
    module ChildNavigable
      module_function

      BLANK_HTML = "<!DOCTYPE html><html><head></head><body></body></html>"

      # URL "matches about:blank": scheme about, path "blank", no credentials
      # and no host (a query or fragment is allowed).
      def matches_about_blank?(url)
        record = UrlParser.parse(url.to_s)
        record.scheme == "about" && UrlParser.serialize_path(record) == "blank" &&
          record.username.to_s.empty? && record.password.to_s.empty? && record.host.nil?
      rescue UrlParser::Failure
        false
      end

      # The URL without its fragment, for "equals with exclude fragments".
      def without_fragment(url)
        url.to_s.sub(/#.*\z/m, "")
      end

      # The document (as its Window) for a response to a child navigable's
      # navigation: HTML parsed as HTML, an XML type parsed as XML, anything
      # else shown as text. A response that names no type is typed by the
      # extension of its URL's path, as a static file server would.
      def window_for_response(body, content_type, url)
        type = content_type.to_s.split(";").first.to_s.strip.downcase
        type = type_for_path(url) if type.empty?
        body = body.to_s.dup.force_encoding(Encoding::UTF_8).scrub
        win =
          if xml_type?(type)
            w = Window.new(nil, backend_doc: Backend.parse_xml(body.to_s))
            w.document.content_type = type
            w
          elsif type == "text/html"
            Dommy.parse(body.to_s)
          else
            text_window(body)
          end
        win.location.__internal_set_url__(url.to_s)
        win
      end

      # The document a data: or blob: URL navigates to, or nil for any other
      # URL (and for a blob URL that resolves to nothing).
      def window_for_local_url(url)
        if url.start_with?("data:")
          parsed = DataUri.parse(url)
          return nil unless parsed

          return window_for_response(parsed[:body], parsed[:content_type], url)
        end
        return nil unless url.start_with?("blob:")

        blob = URL.__test_resolve_blob_url__(url.sub(/#.*\z/m, ""))
        return nil unless blob

        window_for_response(blob.text, blob.type.to_s.empty? ? "text/plain" : blob.type, url)
      end

      XML_TYPES = %w[text/xml application/xml application/xhtml+xml image/svg+xml].freeze

      def xml_type?(type)
        XML_TYPES.include?(type) || type.end_with?("+xml")
      end

      PATH_TYPES = {
        ".xhtml" => "application/xhtml+xml", ".xht" => "application/xhtml+xml",
        ".xml" => "application/xml", ".svg" => "image/svg+xml",
        ".txt" => "text/plain", ".js" => "text/javascript", ".json" => "application/json",
        ".css" => "text/css", ".pdf" => "application/pdf", ".png" => "image/png",
        ".jpg" => "image/jpeg", ".gif" => "image/gif"
      }.freeze

      def type_for_path(url)
        path = url.to_s.sub(/[?#].*\z/m, "")
        PATH_TYPES.find { |ext, _| path.end_with?(ext) }&.last || "text/html"
      end

      # The document a navigation that met a network error shows (HTML "create
      # a document for inline content"): empty, with a new opaque origin, so a
      # container's script cannot reach into it.
      def error_window(url)
        win = Dommy.parse(BLANK_HTML)
        win.location.__internal_set_url__(url.to_s)
        win.__internal_opaque_origin__ = true
        win
      end

      def text_window(body)
        win = Dommy.parse(BLANK_HTML)
        pre = win.document.create_element("pre")
        pre.text_content = body
        win.document.body.append_child(pre)
        win
      end

      # The navigation delegate of a window whose document is a child
      # navigable's active document: a navigation from inside it (its
      # location, a link or form in it) navigates that child navigable, and a
      # frame of its own is loaded the way its parent's frames are.
      class Delegate
        def initialize(container)
          @container = container
        end

        def navigate(url:, source:, method: "GET", body: nil, params: nil, enctype: nil, target: nil, headers: {}, replace: false)
          @container.__internal_navigate_content__(
            url.to_s,
            nav: {method: method, body: body, params: params, enctype: enctype, headers: headers, source: source},
            replace: replace
          )
          nil
        end

        def traverse(_delta) = nil

        def history_length
          parent = parent_delegate
          parent.history_length if parent.respond_to?(:history_length)
        end

        # A grandchild's navigation goes wherever this frame's own would.
        def load_frame(frame, **nav)
          parent = parent_delegate
          parent.load_frame(frame, **nav) if parent.respond_to?(:load_frame)
        end

        # A popup opened from inside the frame is its top-level embedder's.
        def open_window(**opts)
          parent = parent_delegate
          parent.open_window(**opts) if parent.respond_to?(:open_window)
        end

        private

        def parent_delegate
          @container.owner_document&.default_view&.navigation_delegate
        end
      end
    end
  end
end
