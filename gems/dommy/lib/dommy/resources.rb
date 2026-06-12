# frozen_string_literal: true

require "uri"

module Dommy
  # The single interface through which the lightweight test browser resolves
  # external resources — both `<script src>` loads and `fetch` / XHR. A real
  # browser routes both through one network layer, so Dommy does too: a
  # `Resources` adapter answers `#get` / `#request` with a `Response`, and the
  # same adapter can be installed as the window's fetch handler.
  #
  # An adapter returns `nil` from `#request` when it does not serve a URL, so
  # callers fall through (to the next adapter in a `chain`, or to the stub maps
  # behind `window.fetch`). Built-in adapters: `static`, `file_system`, `chain`.
  # `Dommy::Rack::Resources` (in dommy-rack) serves a Rack app.
  module Resources
    # A resolved resource. `status_text` is filled by whichever adapter built
    # it (the Rack adapter uses Rack::Utils; the core adapters leave it blank or
    # derive a minimal default) so the core stays Rails/Rack-independent.
    Response = Struct.new(:status, :status_text, :headers, :body, :url, :redirected, keyword_init: true) do
      def success? = (200..299).cover?(status.to_i)
    end

    class << self
      # An in-memory adapter. `map` keys are matched against the request URL as
      # given AND its path component, so `{ "/app.js" => "..." }` serves both
      # `/app.js` and `http://host/app.js`. A value is either a body String or a
      # Hash with "status" / "headers" / "body" / "content_type".
      def static(map) = Static.new(map)

      # Serve files under `root` for URLs whose path starts with `base_url`.
      # `file_system(root: "dist", base_url: "/assets")` maps the request path
      # `/assets/app.js` to the file `dist/app.js`. Missing files return nil.
      def file_system(root:, base_url: "/") = FileSystem.new(root, base_url)

      # Try each adapter in order; the first non-nil Response wins.
      def chain(*adapters) = Chain.new(adapters)
    end

    # Maps a Resources adapter onto the `__fetch_handler__` callable contract
    # (`call(url, init) -> entry Hash | nil`) consumed by FetchFn / XHR, so the
    # same Resources resolves window.fetch. A nil Response passes through to the
    # stub maps.
    class FetchHandler
      def initialize(resources)
        @resources = resources
      end

      def call(url, init = nil)
        init = {} unless init.is_a?(Hash)
        response = @resources.request(
          method: (init["method"] || "GET").to_s.upcase,
          url: url.to_s,
          headers: init["headers"].is_a?(Hash) ? init["headers"] : {},
          body: init["body"]&.to_s
        )
        return nil unless response

        {
          "status" => response.status,
          "statusText" => response.status_text.to_s,
          "body" => response.body.to_s,
          "headers" => response.headers || {},
          "url" => response.url || url.to_s,
          "redirected" => response.redirected ? true : false
        }
      end
    end

    # Common helpers for the built-in adapters.
    module Pathing
      module_function

      def path_of(url)
        URI.parse(url.to_s).path
      rescue URI::InvalidURIError
        url.to_s
      end
    end

    class Static
      def initialize(map)
        @map = map || {}
      end

      def get(url, headers: {}) = request(method: "GET", url: url, headers: headers)

      def request(method:, url:, headers: {}, body: nil)
        entry = @map[url.to_s] || @map[Pathing.path_of(url)]
        return nil unless entry

        if entry.is_a?(Hash)
          ct = entry["content_type"] || entry["contentType"]
          Response.new(
            status: (entry["status"] || 200).to_i,
            status_text: entry["status_text"].to_s,
            headers: entry["headers"] || (ct ? {"Content-Type" => ct} : {}),
            body: entry["body"].to_s,
            url: url.to_s,
            redirected: false
          )
        else
          Response.new(status: 200, status_text: "OK", headers: {}, body: entry.to_s, url: url.to_s, redirected: false)
        end
      end
    end

    class FileSystem
      def initialize(root, base_url)
        @root = ::File.expand_path(root.to_s)
        @base = base_url.to_s.sub(%r{/\z}, "")
      end

      def get(url, headers: {}) = request(method: "GET", url: url, headers: headers)

      def request(method:, url:, headers: {}, body: nil)
        path = Pathing.path_of(url)
        return nil unless @base.empty? || path.start_with?("#{@base}/") || path == @base

        rel = @base.empty? ? path : path[@base.length..]
        file = ::File.expand_path(rel.sub(%r{\A/}, ""), @root)
        # Containment guard: never escape `root`.
        return nil unless file == @root || file.start_with?("#{@root}/")
        return nil unless ::File.file?(file)

        Response.new(status: 200, status_text: "OK", headers: {}, body: ::File.read(file), url: url.to_s, redirected: false)
      end
    end

    class Chain
      def initialize(adapters)
        @adapters = adapters.compact
      end

      def get(url, headers: {}) = request(method: "GET", url: url, headers: headers)

      def request(method:, url:, headers: {}, body: nil)
        @adapters.each do |adapter|
          response = adapter.request(method: method, url: url, headers: headers, body: body)
          return response if response
        end
        nil
      end
    end
  end
end
