# frozen_string_literal: true

require_relative "test_helper"

# Covers the `__fetch_handler__` seam: a callable installed in window
# globals that resolves fetch/XHR requests before the stub maps are
# consulted (the hook dommy-rack's NetworkBridge plugs into).
class TestFetchHandler < Minitest::Test
  include DommyTestHelper

  class RecordingHandler
    attr_reader :calls

    def initialize(entries)
      @entries = entries
      @calls = []
    end

    def call(url, init)
      @calls << [url, init]
      @entries[url]
    end
  end

  def setup
    @win = make_window
    # The request URL is resolved against the document base before it reaches
    # the handler, so the handler is keyed by the absolute URL.
    @handler = RecordingHandler.new(
      "http://localhost/app" => {"status" => 201, "body" => "from handler", "headers" => {"Content-Type" => "text/plain"}}
    )
    @win.globals["__fetch_handler__"] = @handler
    # A stub may still be keyed by path; it matches the resolved URL's path.
    @win.globals["__fetchy_stub__"] = {"/stubbed" => {"status" => 200, "body" => "from stub"}}
  end

  def test_fetch_resolves_through_the_handler
    response = Dommy::FetchFn.new(@win).__js_call__("fetch", ["/app", {"method" => "POST", "body" => "data"}]).await

    assert_equal 201, response.__js_get__("status")
    assert_equal "from handler", response.__js_call__("text", []).await
    url, init = @handler.calls.last
    assert_equal "http://localhost/app", url
    assert_equal "POST", init["method"]
    assert_equal "data", init["body"]
  end

  def test_fetch_falls_through_to_stub_when_handler_declines
    response = Dommy::FetchFn.new(@win).__js_call__("fetch", ["/stubbed", nil]).await

    assert_equal "from stub", response.__js_call__("text", []).await
    assert_equal "http://localhost/stubbed", @handler.calls.last.first
  end

  def test_xhr_resolves_through_the_handler_with_request_init
    xhr = Dommy::XMLHttpRequest.new(@win)
    xhr.open("POST", "/app", false)
    xhr.set_request_header("X-Token", "t1")
    xhr.send("payload")

    assert_equal 201, xhr.__js_get__("status")
    assert_equal "from handler", xhr.__js_get__("responseText")
    url, init = @handler.calls.last
    assert_equal "http://localhost/app", url
    assert_equal "POST", init["method"]
    assert_equal "payload", init["body"]
    assert_equal "t1", init["headers"]["X-Token"]
  end

  def test_xhr_falls_through_to_stub_when_handler_declines
    xhr = Dommy::XMLHttpRequest.new(@win)
    xhr.open("GET", "/stubbed", false)
    xhr.send

    assert_equal "from stub", xhr.__js_get__("responseText")
  end

  # --- Off-thread (executor) path ---

  # A Resources adapter for the async path: request_job makes the serve decision
  # (page thread) and returns a worker-safe thunk producing a Resources::Response,
  # or nil for a URL it does not serve.
  class AsyncResources
    def initialize(entries) = @entries = entries

    def request_job(method:, url:, headers: {}, body: nil)
      entry = @entries[url]
      return nil unless entry

      lambda do
        next entry[:error] && raise("boom") if entry[:error]

        Dommy::Resources::Response.new(
          status: entry[:status], status_text: "OK", headers: {},
          body: entry[:body], url: url, redirected: false
        )
      end
    end
  end

  # Captures submissions so a test can run them deterministically. #run_all runs
  # each job on a real worker thread (proving the work is off the page thread)
  # and joins before handing the result back.
  class ManualExecutor
    attr_reader :pending

    def initialize = @pending = []
    def submit(job, &on_result) = (@pending << [job, on_result]) && self

    def run_all
      @pending.each do |job, on_result|
        # Mirror a real pool: a job failure crosses back as a nil result.
        Thread.new { on_result.call(begin; job.call; rescue StandardError; nil; end) }.join
      end
      @pending.clear
    end
  end

  def async_handler(entries)
    @executor = ManualExecutor.new
    handler = Dommy::Resources::FetchHandler.new(
      AsyncResources.new(entries), executor: @executor, scheduler: @win.scheduler
    )
    @win.globals["__fetch_handler__"] = handler
  end

  def test_fetch_defers_to_the_executor_and_resolves_on_the_page_thread
    async_handler("http://localhost/api" => {status: 200, body: "async!"})

    promise = Dommy::FetchFn.new(@win).__js_call__("fetch", ["/api", nil])
    refute_empty @executor.pending, "the request was handed to the executor, not run inline"

    @executor.run_all              # worker thread runs the job + completes the deferred
    @win.scheduler.advance_time(0) # delivered on the page thread via the inbox

    response = promise.await
    assert_equal 200, response.__js_get__("status")
    assert_equal "async!", response.__js_call__("text", []).await
  end

  def test_unserved_url_falls_through_to_stub_without_touching_the_executor
    async_handler({}) # serves nothing -> request_job returns nil synchronously

    response = Dommy::FetchFn.new(@win).__js_call__("fetch", ["/stubbed", nil]).await

    assert_equal "from stub", response.__js_call__("text", []).await
    assert_empty @executor.pending, "an unserved URL is decided on the page thread, never queued"
  end

  def test_a_worker_failure_resolves_as_a_miss
    async_handler("http://localhost/api" => {error: true})

    promise = Dommy::FetchFn.new(@win).__js_call__("fetch", ["/api", nil])
    @executor.run_all # the job raises -> the executor hands back nil
    @win.scheduler.advance_time(0)

    assert_equal 404, promise.await.__js_get__("status")
  end
end
