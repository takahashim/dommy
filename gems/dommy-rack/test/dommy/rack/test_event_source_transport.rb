# frozen_string_literal: true

require "test_helper"

class Dommy::Rack::TestEventSourceTransport < Minitest::Test
  include RackTestHelper

  # Records the transport callbacks a real Dommy::EventSource would receive.
  class FakeEventSource
    attr_reader :opens, :messages, :errors, :closes

    def initialize
      @opens = 0
      @messages = []
      @errors = 0
      @closes = 0
    end

    def __transport_open__ = @opens += 1
    def __transport_message__(data, event:, id: nil) = @messages << [data, event, id]
    def __transport_error__ = @errors += 1
    def __transport_closed__ = @closes += 1
  end

  # A Rack app streaming a fixed text/event-stream body.
  def sse_app(body)
    lambda do |env|
      next [404, {"Content-Type" => "text/plain"}, ["Not Found"]] unless env["PATH_INFO"] == "/events"

      [200, {"Content-Type" => "text/event-stream"}, [body]]
    end
  end

  def build_transport(body, es: FakeEventSource.new, scheduler: Dommy::Scheduler.new)
    transport = Dommy::Rack::EventSourceTransport.new(
      app: sse_app(body), es: es, scheduler: scheduler,
      url: Dommy::URL.new("http://example.org/events"), origin: "http://example.org"
    )
    @transports << transport
    [transport, es, scheduler]
  end

  def drain_until(scheduler, what = "condition")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    loop do
      scheduler.advance_time(0)
      return if yield

      flunk "timed out waiting for #{what}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.005
    end
  end

  def setup
    @transports = []
  end

  def teardown
    @transports.each(&:dispose)
  end

  def test_open_then_named_and_default_events_with_ids
    body = "event: greeting\ndata: hello\nid: 1\n\n" \
           "data: plain\n\n"
    _transport, es, scheduler = build_transport(body)

    drain_until(scheduler, "two messages") { es.messages.size >= 2 }
    assert_equal 1, es.opens
    assert_equal [["hello", "greeting", "1"], ["plain", "message", "1"]], es.messages
    assert_equal 0, es.errors
  end

  def test_multiline_data_is_joined_with_newlines
    _transport, es, scheduler = build_transport("data: line1\ndata: line2\n\n")

    drain_until(scheduler, "message") { es.messages.any? }
    assert_equal [["line1\nline2", "message", nil]], es.messages
  end

  def test_comment_and_heartbeat_lines_are_ignored
    _transport, es, scheduler = build_transport(": keep-alive\n\n\ndata: after\n\n")

    drain_until(scheduler, "message") { es.messages.any? }
    assert_equal [["after", "message", nil]], es.messages
  end

  def test_stream_end_reports_error_once
    _transport, es, scheduler = build_transport("data: only\n\n")

    drain_until(scheduler, "close") { es.closes.positive? }
    assert_equal 1, es.opens
    assert_equal [["only", "message", nil]], es.messages
    assert_equal 0, es.errors
  end

  def test_non_success_status_reports_error
    es = FakeEventSource.new
    scheduler = Dommy::Scheduler.new
    app = ->(_env) { [500, {"Content-Type" => "text/plain"}, ["boom"]] }
    transport = Dommy::Rack::EventSourceTransport.new(
      app: app, es: es, scheduler: scheduler,
      url: Dommy::URL.new("http://example.org/events"), origin: "http://example.org"
    )
    @transports << transport

    drain_until(scheduler, "error") { es.errors.positive? }
    assert_equal 0, es.opens
  end

  def test_cross_origin_url_is_not_a_rack_target
    base = "http://example.org/page"
    assert Dommy::Rack::EventSourceTransport.rack_target("/events", base: base)
    assert Dommy::Rack::EventSourceTransport.rack_target("http://example.org/events", base: base)
    assert_nil Dommy::Rack::EventSourceTransport.rack_target("http://other.example/events", base: base)
    assert_nil Dommy::Rack::EventSourceTransport.rack_target("mailto:user@example.org", base: base)
  end

  # Session-level integration without a JS engine: install the connector seam
  # by hand (SessionRuntime does the same for JS realms) and open a
  # Dommy::EventSource from Ruby.
  def test_session_connector_streams_from_the_app
    app = lambda do |env|
      next sse_app("data: streamed\n\n").call(env) if env["PATH_INFO"] == "/events"

      html_response("<h1>Home</h1>")
    end
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    window = session.document.default_view
    window.event_source_connector = session.__internal_event_source_connector(window)

    es = Dommy::EventSource.new(window, "/events")
    received = []
    es.add_event_listener("message", ->(event) { received << event.data })

    drain_until(window.scheduler, "message") { received.any? }
    assert_equal ["streamed"], received
  ensure
    session&.dispose
  end
end
