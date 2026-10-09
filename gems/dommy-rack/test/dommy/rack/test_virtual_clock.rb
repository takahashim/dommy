# frozen_string_literal: true

require "test_helper"
require "support/null_runtime"

# What a JS-enabled session tells a waiting host about its virtual clock: the
# time, the delay to the next timer, and whether anything can arrive from
# outside the clock.
class Dommy::Rack::TestVirtualClock < Minitest::Test
  include RackTestHelper

  def setup
    @previous_factory = DommyRackTestSupport::NullRuntimeBackend.install
    @session = Dommy::Rack::Session.new(app_for("GET /" => html_response("<p>x</p>")), javascript: true)
    @session.visit("/")
  end

  def teardown
    @session.dispose
    DommyRackTestSupport::NullRuntimeBackend.restore(@previous_factory)
  end

  def scheduler = @session.document.default_view.scheduler

  def test_next_timer_delay_counts_from_the_current_time
    assert_nil @session.next_timer_delay

    scheduler.set_timeout(-> {}, 300)
    @session.advance_time(100)
    assert_equal 100, @session.virtual_time
    assert_equal 200, @session.next_timer_delay
  end

  def test_a_session_without_javascript_has_no_clock
    session = Dommy::Rack::Session.new(app_for("GET /" => html_response("<p>x</p>")))
    session.visit("/")
    assert_nil session.virtual_time
    assert_nil session.next_timer_delay
    refute session.completion_pending?
    refute session.open_connections?
  end

  def test_a_completion_is_pending_until_the_loop_turns
    refute @session.completion_pending?

    scheduler.post_external {}
    assert @session.completion_pending?
    @session.advance_time(0)
    refute @session.completion_pending?
  end

  def test_connections_are_open_until_closed
    transport = Struct.new(:closed) do
      def closed? = closed
      def dispose(wait: true) = nil
    end.new(false)
    @session.instance_variable_set(:@live_websocket_transports, [transport])
    assert @session.open_connections?

    transport.closed = true
    refute @session.open_connections?
  end

  # Unloading a page closes the EventSources and WebSockets it and its frames
  # opened, so the next page is not kept waiting on them — and the navigation
  # does not wait for a reader stuck in a streaming body.
  def test_navigating_away_closes_the_pages_connections
    app = lambda do |env|
      case env["PATH_INFO"]
      when "/events" then [200, {"Content-Type" => "text/event-stream"}, Enumerator.new { |y| y << "data: x\n\n"; sleep 3 }]
      else [200, {"Content-Type" => "text/html"}, ["<p>x</p>"]]
      end
    end
    session = Dommy::Rack::Session.new(app, javascript: true)
    session.visit("/a")
    es = Object.new
    def es.method_missing(*) = nil
    def es.respond_to_missing?(*) = true
    frame_window = Dommy.parse("<p>frame</p>")
    transports = [session.document.default_view, frame_window].map do |window|
      session.__internal_event_source_connector(window).call(es, "/events", false)
    end
    assert session.open_connections?

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    session.visit("/b")
    assert Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 0.5, "navigation waited for the readers"
    assert transports.all?(&:closed?)
    refute session.open_connections?
  ensure
    session&.dispose
  end

  def test_a_connection_that_ended_leaves_the_session_s_lists
    transport = Struct.new(:closed) do
      def closed? = closed
      def dispose(wait: true) = nil
    end.new(false)
    @session.instance_variable_set(:@live_event_source_transports, [transport])
    assert @session.open_connections?

    transport.closed = true
    refute @session.open_connections?
    assert_empty @session.instance_variable_get(:@live_event_source_transports)
  end
end
