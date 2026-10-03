# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/null_runtime"

# A page's big ES modules are registered with the engine once a page has run,
# and the next runtime for the same origin is built with them preloaded, so
# they are read as bytecode rather than parsed again (Js::ModulePreload).
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

  def setup
    PreloadingRuntime.registry = {}
    PreloadingRuntime.refuse = false
    Dommy::Js.register_runtime(:preloading) { |**opts| PreloadingRuntime.new(**opts) }
    PRELOAD.reset!
    PRELOAD.enabled = true
    @resources = Dommy::Resources.static("/big.js" => BIG, "/small.js" => SMALL)
  end

  def teardown
    PRELOAD.enabled = false
    PRELOAD.reset!
  end

  def page(body, url: "http://localhost/")
    Dommy::Browser.new("<html><body>#{body}</body></html>", url: url, backend: :preloading, resources: @resources)
  end

  def modules(*paths) = paths.map { |path| %(<script type="module" src="#{path}"></script>) }.join

  def runtime_of(browser) = browser.instance_variable_get(:@runtime)

  def test_a_big_module_is_registered_once_a_page_has_run
    page(modules("/big.js", "/small.js"))
    assert_equal ["http://localhost/big.js"], PreloadingRuntime.registry.keys
  end

  def test_the_next_page_of_the_origin_preloads_it
    page(modules("/big.js"))
    runtime = runtime_of(page(modules("/big.js")))

    assert_equal ["http://localhost/big.js"], runtime.preload_modules
    assert_empty runtime.asked, "a preloaded module is not asked of the loader"
    assert_equal ["http://localhost/big.js"], PRELOAD.preloaded(runtime)
  end

  # A bare specifier the import map resolves to a preloaded module is
  # redirected to it.
  def test_the_loader_redirects_to_a_preloaded_module
    page(modules("/big.js"))
    runtime = runtime_of(page(%(<script type="importmap">{"imports": {"big": "/big.js"}}</script>)))

    assert_equal({as: "http://localhost/big.js"}, runtime.module_loader.call("big", nil))
  end

  def test_another_origin_preloads_nothing
    page(modules("/big.js"))
    assert_empty runtime_of(page("", url: "http://example.test/")).preload_modules
  end

  def test_off_unless_enabled
    PRELOAD.enabled = false
    page(modules("/big.js"))
    assert_empty PreloadingRuntime.registry
  end

  # Should the engine refuse the preload, the page boots without it, and the
  # modules are not offered again.
  def test_a_refused_preload_falls_back_and_is_not_offered_again
    page(modules("/big.js"))
    PreloadingRuntime.refuse = true
    first = runtime_of(page(modules("/big.js")))
    PreloadingRuntime.refuse = false
    second = runtime_of(page(modules("/big.js")))

    assert_equal [[], ["http://localhost/big.js"]], [first.preload_modules, first.asked]
    assert_empty second.preload_modules
  end

  # An engine without the registry is built as before.
  def test_an_engine_without_preloading_is_left_alone
    browser = Dommy::Browser.new("<html><body>#{modules("/big.js")}</body></html>", backend: :null, resources: @resources)
    assert_empty PRELOAD.preloaded(runtime_of(browser))
    assert_kind_of DommyTestSupport::NullRuntime, runtime_of(browser)
  end
end
