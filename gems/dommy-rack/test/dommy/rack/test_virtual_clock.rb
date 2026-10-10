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
    refute session.fetch_in_flight?
  end

  def test_a_completion_is_pending_until_the_loop_turns
    refute @session.completion_pending?

    scheduler.post_external {}
    assert @session.completion_pending?
    @session.advance_time(0)
    refute @session.completion_pending?
  end

  FakeTransport = Struct.new(:closed, :disposed) do
    def closed? = closed
    def dispose(wait: true) = (self.disposed = true)
  end

  def open_fake_connection(window)
    transport = FakeTransport.new(false, false)
    (@session.instance_variable_get(:@page_connections) || @session.instance_variable_set(:@page_connections, [])) << [window, transport]
    transport
  end

  def frame_window
    @session.document.body.inner_html = "<iframe></iframe>"
    @session.document.query_selector("iframe").content_window
  end

  def test_connections_are_open_until_closed
    transport = open_fake_connection(@session.document.default_view)
    assert @session.open_connections?

    transport.closed = true
    refute @session.open_connections?
    assert_empty @session.instance_variable_get(:@page_connections)
  end

  # Unloading a page closes the EventSources and WebSockets it and its frames
  # opened, so the next page is not kept waiting on them — and the navigation
  # does not wait for a reader stuck in a streaming body.
  def test_navigating_away_closes_the_pages_connections
    app = lambda do |env|
      case env["PATH_INFO"]
      when "/events" then [200, {"Content-Type" => "text/event-stream"}, Enumerator.new { |y| y << "data: x\n\n"; sleep 3 }]
      else [200, {"Content-Type" => "text/html"}, ["<p>x</p><iframe></iframe>"]]
      end
    end
    session = Dommy::Rack::Session.new(app, javascript: true)
    session.visit("/a")
    es = Object.new
    def es.method_missing(*) = nil
    def es.respond_to_missing?(*) = true
    windows = [session.document.default_view, session.document.query_selector("iframe").content_window]
    transports = windows.map do |window|
      session.__internal_event_source_connector(window).call(es, "/events", false)
    end
    assert session.open_connections?

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    session.visit("/b")
    assert Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 0.5, "navigation waited for the readers"
    assert transports.all?(&:closed?)
    refute session.open_connections?
    refute session.fetch_in_flight?
  ensure
    session&.dispose
  end

  # A frame's connections close with the frame's document, while the page's
  # own stay open.
  def test_a_removed_frame_s_connections_close
    page = open_fake_connection(@session.document.default_view)
    frame = open_fake_connection(frame_window)
    assert @session.open_connections?

    @session.document.query_selector("iframe").remove
    assert @session.open_connections?
    assert frame.disposed
    refute page.disposed
    assert_equal [page], @session.instance_variable_get(:@page_connections).map(&:last)
  end

  def test_a_frame_navigated_away_closes_its_connections
    window = frame_window
    frame = open_fake_connection(window)
    window.__internal_discard__
    refute @session.open_connections?
    assert frame.disposed
  end

  # A fetch on a worker counts as in flight in any realm, the frames' too.
  def test_a_fetch_in_flight_in_a_frame_is_seen
    refute @session.fetch_in_flight?
    window = frame_window
    @session.instance_variable_get(:@js_runtime).runtime_for(window.document)
    window.scheduler.begin_external_work
    assert @session.fetch_in_flight?
    window.scheduler.end_external_work
    refute @session.fetch_in_flight?
  end

  # Every realm's clock moves together, and the next timer is the soonest in
  # any of them.
  def test_the_clock_moves_every_realm
    window = frame_window
    @session.instance_variable_get(:@js_runtime).runtime_for(window.document)
    fired = []
    scheduler.set_timeout(-> { fired << :page }, 300)
    window.scheduler.set_timeout(-> { fired << :frame }, 100)
    assert_equal 100, @session.next_timer_delay

    @session.advance_time(100)
    assert_equal [:frame], fired
    assert_equal 200, @session.next_timer_delay
    @session.advance_time(200)
    assert_equal %i[frame page], fired
  end

  def test_a_completion_for_a_frame_is_delivered
    window = frame_window
    @session.instance_variable_get(:@js_runtime).runtime_for(window.document)
    delivered = false
    window.scheduler.post_external { delivered = true }
    assert @session.completion_pending?
    @session.advance_time(0)
    assert delivered
    refute @session.completion_pending?
  end

  def framed_realm
    window = frame_window
    @session.instance_variable_get(:@js_runtime).runtime_for(window.document)
    window
  end

  # settle reaches a frame's ready work too: its due-now timers and its next
  # animation frame.
  def test_settle_runs_a_frames_ready_work
    window = framed_realm
    ran = []
    window.scheduler.set_timeout(-> { ran << :timer }, 0)
    window.scheduler.request_animation_frame(->(_t) { ran << :frame })

    @session.settle
    assert_equal %i[timer frame], ran
  end

  # A frame that hands the page work ready at once is followed by the page
  # settling that work in the same call.
  def test_settle_follows_work_one_realm_hands_another
    window = framed_realm
    ran = []
    window.scheduler.request_animation_frame(lambda do |_t|
      ran << :frame
      scheduler.set_timeout(-> { ran << :page }, 0)
    end)

    @session.settle
    assert_equal %i[frame page], ran
  end

  # An animation requesting one frame after another does not keep settle
  # going: it runs the next frame and returns.
  def test_settle_returns_on_an_endless_animation
    window = framed_realm
    frames = 0
    tick = nil
    tick = ->(_t) { frames += 1; window.scheduler.request_animation_frame(tick) }
    window.scheduler.request_animation_frame(tick)

    @session.settle
    assert_operator frames, :<=, 2
  end
end
