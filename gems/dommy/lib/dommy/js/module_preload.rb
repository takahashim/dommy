# frozen_string_literal: true

require "uri"

module Dommy
  module Js
    # Keeps a page's ES modules for the next page instead of fetching and
    # parsing them again. A test suite boots the same bundles — Turbo,
    # Stimulus, an app's controllers and vendored libraries — page after
    # page, each in a runtime of its own; fetching them through the app and
    # parsing them is most of what booting costs.
    #
    # Once a page has run, each module its loader fetched is kept, once per
    # process: its source, which the next page's loader answers from without
    # a request, and — when it is big enough to be worth it (MIN_BYTES; a
    # small one reads as bytecode slower than it parses) — its registration
    # with the engine under its resolved URL. Every later runtime for a page
    # of the same origin is built with the registered modules preloaded: the
    # engine finds one by its URL before asking the loader, and the loader
    # answers a bare specifier the import map resolves to one with a
    # redirect to it.
    #
    # A kept module is never fetched again, so which ones are kept is the
    # `scope`: :digested (the default) keeps only those whose URL carries a
    # digest of their content (`application-f004202c.js`, the way Propshaft,
    # Sprockets and the bundlers name what they serve), which no change to
    # the source can leave in place; :all keeps every one, for an app that
    # serves modules under fixed names and does not change them while the
    # process runs; :none keeps none.
    #
    # The kept sources are capped (MAX_SOURCE_BYTES, the least recently read
    # going first), so a process that browses site after site does not grow
    # without bound; a module dropped is fetched again when next asked for.
    # A kept source is used only for a URL the page's resources would serve
    # (ModuleLoader asks), so a host an embedder blocks stays blocked.
    #
    # The engine side is optional: a runtime class that has
    # `register_module(name, source:)`, and that takes `preload_modules:` when
    # built (dommy-js-quickjs's Runtime does). With any other, only the
    # sources are kept and runtimes are built as before.
    module ModulePreload
      # The size, in bytes, from which a module's bytecode reads faster than
      # its source parses.
      MIN_BYTES = 10_000

      # The most source, in bytes, kept at once: far above a test suite's
      # bundles, a bound for a long-running browser.
      MAX_SOURCE_BYTES = 64 * 1024 * 1024

      # The last path segment of a digested asset: a name, then `-` or `.`
      # and at least seven hex digits (Propshaft's 8, Webpack's 20,
      # Sprockets' 64) with a digit among them, then the extension.
      DIGESTED = /[-.](?=[0-9a-f]*[0-9])[0-9a-f]{7,}\.[a-z0-9]+\z/
      SCOPES = %i[digested all none].freeze

      @scope = :digested
      @registered = {}
      @sources = {}
      @source_bytes = 0
      @max_source_bytes = MAX_SOURCE_BYTES
      @preloaded = ObjectSpace::WeakMap.new
      @mutex = Mutex.new

      class << self
        attr_reader :scope

        # The cap on kept source (MAX_SOURCE_BYTES unless changed).
        attr_accessor :max_source_bytes

        def scope=(value)
          raise ArgumentError, "scope must be one of #{SCOPES.inspect}" unless SCOPES.include?(value)

          @scope = value
        end

        # Whether a module fetched from `url` is kept for the next page.
        def keeps?(url)
          case @scope
          when :all then true
          when :digested then digested?(url)
          else false
          end
        end

        # Whether `url`'s file name carries a digest of its content.
        def digested?(url)
          path = URI.parse(url.to_s).path
          !path.nil? && DIGESTED.match?(path)
        rescue URI::InvalidURIError
          false
        end

        # The kept source of the module fetched from `url`, or nil.
        def source(url)
          return nil unless keeps?(url)

          @mutex.synchronize do
            source = @sources.delete(url)
            @sources[url] = source if source # the most recently read last
          end
        end

        # A runtime for `document` from the named backend (or the default),
        # with the registered modules of its origin preloaded. Should the
        # engine refuse them, the runtime is built without, and they are not
        # offered again.
        def build_runtime(document, backend = nil)
          names = names_for(document)
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

        # Keep the modules a page's loader fetched (`served`, URL => source)
        # that the scope covers and are not kept yet: the source of each, and
        # the big ones registered with the engine behind `runtime`.
        def register(runtime, served)
          engine = runtime.class
          served.each do |url, source|
            next unless keeps?(url)

            @mutex.synchronize do
              next if @sources.key?(url)

              keep_source(url, source)
              next if source.bytesize < MIN_BYTES || !engine.respond_to?(:register_module) || @registered.key?(url)

              engine.register_module(url, source: source)
              @registered[url] = true
            end
          rescue StandardError
            next
          end
        end

        # Forget every kept module, for a test that starts from none. The
        # engine keeps what it compiled; it is just not offered again.
        def reset!
          @mutex.synchronize do
            @registered.clear
            @sources.clear
            @source_bytes = 0
          end
        end

        private

        # Under the mutex: keep `source`, then drop the least recently read
        # until the total fits again.
        def keep_source(url, source)
          @sources[url] = source
          @source_bytes += source.bytesize
          while @source_bytes > @max_source_bytes && (oldest = @sources.first)
            @sources.delete(oldest[0])
            @source_bytes -= oldest[1].bytesize
          end
        end

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

          @mutex.synchronize { @registered.select { |_, offered| offered }.keys }.select { |url| origin_of(url) == origin && keeps?(url) }
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
