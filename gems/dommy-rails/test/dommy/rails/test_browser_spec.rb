# frozen_string_literal: true

require "test_helper"
require "dommy/rails/browser_spec"

# Unit-covers Dommy::Rails::BrowserSpec's lifecycle logic (memoization, strict
# JS-error failure, allow_js_errors, dispose-at-teardown) with a stub browser,
# so it needs neither dommy-rack nor a JS runtime. The real JS engine it wraps
# is covered by dommy-js-quickjs's Session-javascript tests.
class TestBrowserSpec < Minitest::Test
  # A stand-in for the JS-enabled session.
  class FakeBrowser
    attr_reader :js_errors
    attr_reader :disposed

    def initialize(errors = [])
      @js_errors = errors
      @disposed = false
    end

    def dispose_js = @disposed = true
  end

  # A host that mixes in BrowserSpec but supplies a stub browser (so it never
  # reaches the real lazy require / Rack app).
  class Host
    include Dommy::Rails::BrowserSpec

    def initialize(browser)
      @stub = browser
    end

    def browser = @stub

    def browser_started? = true
  end

  def test_dommy_browser_app_is_overridable
    app = Object.new
    host = Object.new.extend(Dommy::Rails::BrowserSpec)
    host.define_singleton_method(:dommy_browser_app) { app }
    assert_same app, host.dommy_browser_app
  end

  def test_teardown_disposes_and_passes_when_no_errors
    browser = FakeBrowser.new([])
    host = Host.new(browser)
    host.dommy_browser_teardown
    assert browser.disposed
  end

  def test_teardown_raises_on_uncaught_js_errors
    browser = FakeBrowser.new([RuntimeError.new("boom")])
    host = Host.new(browser)
    err = assert_raises(RuntimeError) { host.dommy_browser_teardown }
    assert_includes err.message, "uncaught JS error"
    assert browser.disposed, "still disposes even when failing"
  end

  def test_allow_js_errors_suppresses_failure
    browser = FakeBrowser.new([])
    host = Host.new(browser)
    host.allow_js_errors { browser.js_errors << RuntimeError.new("expected") }
    host.dommy_browser_teardown # should NOT raise (the error was acknowledged)
    assert browser.disposed
  end

  # A browser stub carrying a trace, for the failure-artifact path.
  class TraceFake
    Trace = Struct.new(:current_page) do
      def to_json(*) = '{"version":"1"}'
      def to_text(**) = "ACTION visit \"/x\""
    end

    attr_reader :js_errors, :disposed

    def initialize
      @js_errors = []
      @disposed = false
    end

    def dispose_js = @disposed = true
    def trace = Trace.new({url: "/x", title: "X"})
    def html = "<html><body>page</body></html>"
    def text = "page"
    def debug = ::Dommy::Interaction::Debug.new(::Dommy.parse(html).document)
  end

  # A host that writes artifacts under a temp dir.
  class ArtifactHost < Host
    attr_reader :dir

    def initialize(browser, dir)
      super(browser)
      @dir = dir
    end

    def dommy_failures_dir = @dir
  end

  def test_failure_saves_artifacts
    Dir.mktmpdir do |tmp|
      browser = TraceFake.new
      host = ArtifactHost.new(browser, tmp)
      host.dommy_browser_after(failed: true, label: "Todos toggles a todo")

      dir = File.join(tmp, "todos-toggles-a-todo")
      assert File.exist?(File.join(dir, "current.html"))
      assert File.exist?(File.join(dir, "trace.json"))
      assert File.exist?(File.join(dir, "trace.txt"))
      assert File.exist?(File.join(dir, "visible-text.txt"))
      assert File.exist?(File.join(dir, "dom-summary.txt"))
      assert_equal "page", File.read(File.join(dir, "visible-text.txt"))
      assert browser.disposed, "still disposes after saving artifacts"
    end
  end

  def test_passing_example_saves_nothing
    Dir.mktmpdir do |tmp|
      browser = TraceFake.new
      host = ArtifactHost.new(browser, tmp)
      host.dommy_browser_after(failed: false, label: "ok")

      assert_empty Dir.children(tmp)
      assert browser.disposed
    end
  end
end
