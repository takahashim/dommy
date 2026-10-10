# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/null_runtime"

# A page's ES modules are kept once a page has run: the next page's loader
# answers from their sources without a request, and the next runtime for the
# same origin is built with the big ones preloaded, read as bytecode rather
# than parsed again (Js::ModulePreload). By default only modules whose URL
# carries a content digest are kept.
class TestModulePreload < Minitest::Test
  PRELOAD = Dommy::Js::ModulePreload

  # A NullRuntime with the engine side of preloading: a process-wide module
  # registry, `preload_modules:` at construction, and a module load that
  # asks the loader unless the module was preloaded — the shape of
  # dommy-js-quickjs's Runtime.
  class PreloadingRuntime < DommyTestSupport::NullRuntime
    class << self
      attr_accessor :registry, :refuse

      def register_module(name, source:)
        registry[name] = source
      end
    end

    attr_reader :preload_modules, :asked

    def initialize(preload_modules: [])
      raise ArgumentError, "refused" if self.class.refuse && !preload_modules.empty?

      super()
      @preload_modules = preload_modules
      @asked = []
    end

    def load_module_url(url)
      super
      return if @preload_modules.include?(url)

      @asked << url
      module_loader.call(url, nil)
    end
  end

  BIG = "export const big = 1;\n#{"// padding\n" * 1_000}"
  SMALL = "export const small = 1;"

  # The resources, counting the requests made of them per path.
  class CountingResources
    attr_reader :requests
    attr_accessor :refuse

    def serves?(_url) = !refuse

    def initialize(inner)
      @inner = inner
      @requests = Hash.new(0)
    end

    def get(url, *rest, **opts)
      @requests[URI.parse(url.to_s).path] += 1
      @inner.get(url, *rest, **opts)
    end

    def respond_to_missing?(name, include_private = false) = @inner.respond_to?(name, include_private) || super
    def method_missing(name, ...) = @inner.respond_to?(name) ? @inner.public_send(name, ...) : super
  end

  BIG_URL = "http://localhost/big-0123abcd.js"
  SMALL_URL = "http://localhost/small-4567ef01.js"

  def setup
    PreloadingRuntime.registry = {}
    PreloadingRuntime.refuse = false
    Dommy::Js.register_runtime(:preloading) { |**opts| PreloadingRuntime.new(**opts) }
    PRELOAD.reset!
    @resources = CountingResources.new(Dommy::Resources.static(
      "/big-0123abcd.js" => BIG, "/small-4567ef01.js" => SMALL, "/plain.js" => SMALL
    ))
  end

  def teardown
    PRELOAD.scope = :digested
    PRELOAD.max_source_bytes = PRELOAD::MAX_SOURCE_BYTES
    PRELOAD.reset!
  end

  def page(body, url: "http://localhost/")
    Dommy::Browser.new("<html><body>#{body}</body></html>", url: url, backend: :preloading, resources: @resources)
  end

  def modules(*paths) = paths.map { |path| %(<script type="module" src="#{path}"></script>) }.join

  def runtime_of(browser) = browser.instance_variable_get(:@runtime)

  def test_a_big_module_is_registered_once_a_page_has_run
    page(modules("/big-0123abcd.js", "/small-4567ef01.js"))
    assert_equal [BIG_URL], PreloadingRuntime.registry.keys
  end

  def test_the_next_page_of_the_origin_preloads_it
    page(modules("/big-0123abcd.js"))
    runtime = runtime_of(page(modules("/big-0123abcd.js")))

    assert_equal [BIG_URL], runtime.preload_modules
    assert_empty runtime.asked, "a preloaded module is not asked of the loader"
    assert_equal [BIG_URL], PRELOAD.preloaded(runtime)
  end

  # A bare specifier the import map resolves to a preloaded module is
  # redirected to it.
  def test_the_loader_redirects_to_a_preloaded_module
    page(modules("/big-0123abcd.js"))
    runtime = runtime_of(page(%(<script type="importmap">{"imports": {"big": "/big-0123abcd.js"}}</script>)))

    assert_equal({as: BIG_URL}, runtime.module_loader.call("big", nil))
  end

  def test_another_origin_preloads_nothing
    page(modules("/big-0123abcd.js"))
    assert_empty runtime_of(page("", url: "http://example.test/")).preload_modules
  end

  def test_none_keeps_nothing
    PRELOAD.scope = :none
    page(modules("/big-0123abcd.js"))
    runtime_of(page(modules("/big-0123abcd.js")))
    assert_empty PreloadingRuntime.registry
    assert_equal 2, @resources.requests["/big-0123abcd.js"]
  end

  # A small module is not worth its bytecode, but its source is kept: the
  # next page does not fetch it again.
  def test_a_kept_module_is_not_fetched_again
    3.times { page(modules("/small-4567ef01.js")) }
    assert_equal 1, @resources.requests["/small-4567ef01.js"]
    assert_equal SMALL, PRELOAD.source(SMALL_URL)
  end

  # A module served under a fixed name could change under it, so it is
  # fetched page after page unless the scope says otherwise.
  def test_a_module_without_a_digest_is_fetched_every_time
    2.times { page(modules("/plain.js")) }
    assert_equal 2, @resources.requests["/plain.js"]
  end

  def test_all_keeps_a_module_without_a_digest
    PRELOAD.scope = :all
    2.times { page(modules("/plain.js")) }
    assert_equal 1, @resources.requests["/plain.js"]
  end

  def test_a_scope_change_stops_offering_what_was_kept
    page(modules("/big-0123abcd.js", "/small-4567ef01.js"))
    PRELOAD.scope = :none
    runtime = runtime_of(page(modules("/big-0123abcd.js", "/small-4567ef01.js")))
    assert_empty runtime.preload_modules
    assert_equal 2, @resources.requests["/small-4567ef01.js"]
  end

  # Past the cap the least recently read source goes, and is fetched again
  # when next asked for.
  def test_kept_sources_are_capped
    PRELOAD.max_source_bytes = SMALL.bytesize + BIG.bytesize - 1
    page(modules("/small-4567ef01.js"))
    page(modules("/big-0123abcd.js"))
    assert_nil PRELOAD.source(SMALL_URL)
    refute_nil PRELOAD.source(BIG_URL)

    page(modules("/small-4567ef01.js"))
    assert_equal 2, @resources.requests["/small-4567ef01.js"]
  end

  # A kept source stands in only for a URL the resources would serve: one
  # they refuse now is asked of them, and refused.
  def test_a_kept_source_is_not_used_for_a_url_the_resources_refuse
    page(modules("/small-4567ef01.js"))
    @resources.refuse = true
    page(modules("/small-4567ef01.js"))
    assert_equal 2, @resources.requests["/small-4567ef01.js"]
  end

  def test_digested_names
    digested = %w[/assets/application-f004202c.js /packs/js/app-0123456789abcdef0123.js /x.1a2b3c4d.mjs
                  /assets/turbo.min-9fd88cd5.js]
    plain = %w[/app.js /assets/my-component.js /assets/x-deadbeef.js /assets/x-1a2b3c.js /a-0123abcd.js/b.js]
    digested.each { |path| assert PRELOAD.digested?("http://localhost#{path}"), path }
    plain.each { |path| refute PRELOAD.digested?("http://localhost#{path}"), path }
    refute PRELOAD.digested?("http://localhost/app.js?v=0123abcd")
  end

  def test_an_unknown_scope_is_refused
    assert_raises(ArgumentError) { PRELOAD.scope = true }
  end

  # Should the engine refuse the preload, the page boots without it, and the
  # modules are not offered again.
  def test_a_refused_preload_falls_back_and_is_not_offered_again
    page(modules("/big-0123abcd.js"))
    PreloadingRuntime.refuse = true
    first = runtime_of(page(modules("/big-0123abcd.js")))
    PreloadingRuntime.refuse = false
    second = runtime_of(page(modules("/big-0123abcd.js")))

    assert_equal [[], [BIG_URL]], [first.preload_modules, first.asked]
    assert_empty second.preload_modules
  end

  # An engine without the registry is built as before.
  def test_an_engine_without_preloading_is_left_alone
    browser = Dommy::Browser.new("<html><body>#{modules("/big-0123abcd.js")}</body></html>", backend: :null, resources: @resources)
    assert_empty PRELOAD.preloaded(runtime_of(browser))
    assert_kind_of DommyTestSupport::NullRuntime, runtime_of(browser)
  end
end
