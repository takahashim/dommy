# frozen_string_literal: true

require "uri"

module Dommy
  module Js
    # Reads a page's big ES modules as bytecode instead of parsing their
    # source again on every page load. A test suite boots the same bundles —
    # Turbo, Stimulus, an app's vendored libraries — page after page, each in
    # a runtime of its own, and parsing them is most of what booting costs.
    #
    # Once a page has run, each module its loader fetched that is big enough
    # to be worth it (MIN_BYTES; a small one reads as bytecode slower than it
    # parses) is registered with the engine under its resolved URL, once per
    # process. Every later runtime for a page of the same origin is built with
    # those modules preloaded: the engine finds one by its URL before asking
    # the loader, and the loader answers a bare specifier the import map
    # resolves to one with a redirect to it.
    #
    # Off unless `enabled`: a preloaded module is never fetched again, so a
    # URL whose content changes within the process — one without a digest in
    # it — would keep running what it served first.
    #
    # The engine side is optional: a runtime class that has
    # `register_module(name, source:)`, and that takes `preload_modules:` when
    # built (dommy-js-quickjs's Runtime does). With any other, nothing is
    # registered and runtimes are built as before.
    module ModulePreload
      # The size, in bytes, from which a module's bytecode reads faster than
      # its source parses.
      MIN_BYTES = 10_000

      @enabled = false
      @registered = {}
      @preloaded = ObjectSpace::WeakMap.new
      @mutex = Mutex.new

      class << self
        attr_accessor :enabled

        # A runtime for `document` from the named backend (or the default),
        # with the registered modules of its origin preloaded. Should the
        # engine refuse them, the runtime is built without, and they are not
        # offered again.
        def build_runtime(document, backend = nil)
          names = enabled ? names_for(document) : []
          return remember(Js.build_runtime(backend), []) if names.empty?

          begin
            remember(Js.build_runtime(backend, preload_modules: names), names)
          rescue StandardError
            refuse(names)
            remember(Js.build_runtime(backend), [])
          end
        end

        # The modules `runtime` was built with preloaded.
        def preloaded(runtime) = @preloaded[runtime] || []

        # Register the modules a page's loader fetched (`served`, URL =>
        # source) that are big enough and not registered yet, with the engine
        # behind `runtime`.
        def register(runtime, served)
          engine = runtime.class
          return unless enabled && engine.respond_to?(:register_module)

          served.each do |url, source|
            next if source.bytesize < MIN_BYTES

            @mutex.synchronize do
              next if @registered.key?(url)

              engine.register_module(url, source: source)
              @registered[url] = true
            end
          rescue StandardError
            next
          end
        end

        # Forget every registration, for a test that starts from none. The
        # engine keeps what it compiled; it is just not offered again.
        def reset!
          @mutex.synchronize { @registered.clear }
        end

        private

        def remember(runtime, names)
          @preloaded[runtime] = names
          runtime
        end

        # Keep the refused names registered but never offered, so they are
        # not compiled and refused again page after page.
        def refuse(names)
          @mutex.synchronize { names.each { |name| @registered[name] = false } }
        end

        def names_for(document)
          origin = origin_of(document&.url)
          return [] if origin.nil?

          @mutex.synchronize { @registered.select { |_, offered| offered }.keys }.select { |url| origin_of(url) == origin }
        end

        def origin_of(url)
          uri = URI.parse(url.to_s)
          uri.host && "#{uri.scheme}://#{uri.host}:#{uri.port}"
        rescue URI::InvalidURIError
          nil
        end
      end
    end
  end
end
