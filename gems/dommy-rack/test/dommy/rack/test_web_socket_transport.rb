# frozen_string_literal: true

require "test_helper"
require "uri"

class Dommy::Rack::TestWebSocketTransport < Minitest::Test
  include RackTestHelper

  # Records the transport callbacks a real Dommy::WebSocket would receive.
  class FakeWebSocket
    attr_reader :opens, :messages, :closes, :errors

    def initialize
      @opens = []
      @messages = []
      @closes = []
      @errors = 0
    end

    def __transport_open__(protocol = nil) = @opens << protocol
    def __transport_message__(data) = @messages << data
    def __transport_closed__(code, reason, was_clean:) = @closes << [code, reason, was_clean]
    def __transport_error__ = @errors += 1
  end

  # --- A tiny in-test Rack WebSocket echo server (RFC 6455 over rack.hijack).

  # Client frames arrive MASKED; echo each text frame back as an UNMASKED
  # server text frame. A close frame is echoed back, then the socket closes.
  def echo_ws_app
    lambda do |env|
      next [404, {"Content-Type" => "text/plain"}, ["Not Found"]] unless env["HTTP_UPGRADE"] == "websocket"

      env["rack.hijack"].call
      io = env["rack.hijack_io"]
      io.write("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
      Thread.new { serve_echo(io) }
      [-1, {}, []]
    end
  end

  def serve_echo(io)
    loop do
      opcode, payload = read_client_frame(io)
      break if opcode.nil?

      case opcode
      when 0x1 # text -> echo
        write_server_frame(io, 0x1, payload)
      when 0x8 # close -> complete the handshake and stop
        write_server_frame(io, 0x8, payload)
        break
      end
    end
  ensure
    begin
      io.close
    rescue IOError
      nil
    end
  end

  def read_client_frame(io)
    head = read_exact(io, 2) or return nil
    b1, b2 = head.unpack("C2")
    length = b2 & 0x7f
    length = read_exact(io, 2).unpack1("n") if length == 126
    length = read_exact(io, 8).unpack1("Q>") if length == 127
    key = (b2 & 0x80).positive? ? read_exact(io, 4) : nil
    payload = length.zero? ? +"" : (read_exact(io, length) or return nil)
    payload = payload.bytes.each_with_index.map { |b, i| b ^ key.getbyte(i % 4) }.pack("C*") if key
    [b1 & 0x0f, payload]
  end

  def write_server_frame(io, opcode, payload)
    header = [0x80 | opcode].pack("C")
    length = payload.bytesize
    header <<
      if length < 126 then [length].pack("C")
      elsif length < 65_536 then [126, length].pack("Cn")
      else [127, length].pack("CQ>")
      end
    io.write(header + payload)
  rescue IOError, Errno::EPIPE
    nil
  end

  def read_exact(io, n)
    data = +""
    while data.bytesize < n
      chunk = io.read(n - data.bytesize)
      return nil if chunk.nil?

      data << chunk
    end
    data
  rescue IOError, Errno::ECONNRESET
    nil
  end

  # --- Helpers ---

  def build_transport(app: echo_ws_app, ws: FakeWebSocket.new, scheduler: Dommy::Scheduler.new)
    transport = Dommy::Rack::WebSocketTransport.new(
      app: app, ws: ws, scheduler: scheduler,
      url: URI.parse("http://example.org/ws"), origin: "http://example.org"
    )
    @transports << transport
    [transport, ws, scheduler]
  end

  # Poll across the reader thread: drain scheduler work, check the condition.
  def drain_until(scheduler, what = "condition")
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
    loop do
      scheduler.advance_time(0) # deliver_external + microtask checkpoint
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

  # --- Tests ---

  def test_open_callback_fires_after_the_101_handshake
    _transport, ws, scheduler = build_transport

    drain_until(scheduler, "open") { !ws.opens.empty? }
    assert_equal [nil], ws.opens
    assert_empty ws.closes
    assert_equal 0, ws.errors
  end

  def test_send_text_round_trips_including_multibyte_utf8
    transport, ws, scheduler = build_transport
    drain_until(scheduler, "open") { !ws.opens.empty? }

    transport.send_text("hello")
    transport.send_text("日本語のメッセージ")

    drain_until(scheduler, "two echoes") { ws.messages.size >= 2 }
    assert_equal ["hello", "日本語のメッセージ"], ws.messages
    assert_equal Encoding::UTF_8, ws.messages.last.encoding
  end

  def test_payload_over_125_bytes_uses_the_16_bit_length_path_intact
    transport, ws, scheduler = build_transport
    drain_until(scheduler, "open") { !ws.opens.empty? }

    big = "x" * 126 + "y" * 300 # > 125 both ways: extended 16-bit length
    transport.send_text(big)

    drain_until(scheduler, "big echo") { ws.messages.any? }
    assert_equal big, ws.messages.first
    assert_equal 426, ws.messages.first.bytesize
  end

  def test_close_completes_the_closing_handshake_cleanly
    transport, ws, scheduler = build_transport
    drain_until(scheduler, "open") { !ws.opens.empty? }

    transport.close(1000, "done")

    drain_until(scheduler, "close") { ws.closes.any? }
    code, _reason, was_clean = ws.closes.first
    assert_equal 1000, code
    assert was_clean, "closing handshake should be clean"
  end

  def test_non_upgrading_app_fails_the_connection_with_error_and_1006
    plain_app = app_for({}) # every request 404s; no hijack happens
    _transport, ws, scheduler = build_transport(app: plain_app)

    drain_until(scheduler, "failure") { ws.closes.any? }
    assert_equal 1, ws.errors
    assert_equal [[1006, "", false]], ws.closes
    assert_empty ws.opens
  end

  def test_rack_target_resolution
    base = "http://example.org/page"

    # Same-origin ws:// resolves, with the scheme rewritten ws -> http.
    same = Dommy::Rack::WebSocketTransport.rack_target("ws://example.org/cable", base: base)
    assert_equal "http://example.org/cable", same.to_s
    assert_equal "http", same.scheme

    relative = Dommy::Rack::WebSocketTransport.rack_target("/cable", base: base)
    assert_equal "http://example.org/cable", relative.to_s

    assert_nil Dommy::Rack::WebSocketTransport.rack_target("ws://other.example/cable", base: base)
    assert_nil Dommy::Rack::WebSocketTransport.rack_target("mailto:user@example.org", base: base)
  end

  # Session-level integration WITHOUT a JS engine: install the session's
  # connector seam by hand (SessionRuntime does the same for JS realms) and
  # open a Dommy::WebSocket from Ruby — it connects to the Rack app itself.
  def test_session_connector_wires_a_websocket_to_the_app
    ws_app = echo_ws_app
    app = lambda do |env|
      next ws_app.call(env) if env["PATH_INFO"] == "/ws"

      html_response("<h1>Home</h1>")
    end
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    window = session.document.default_view
    window.websocket_connector = session.__internal_websocket_connector(window)

    ws = Dommy::WebSocket.new(window, "/ws")
    received = []
    ws.add_event_listener("message", ->(event) { received << event.data })

    drain_until(window.scheduler, "open") { ws.ready_state == Dommy::WebSocket::OPEN }
    ws.send("over the session seam")

    drain_until(window.scheduler, "echo") { received.any? }
    assert_equal ["over the session seam"], received
  ensure
    session&.dispose
  end
end
