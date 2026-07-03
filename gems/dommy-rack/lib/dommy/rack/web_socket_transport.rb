# frozen_string_literal: true

require "socket"
require "securerandom"
require "stringio"
require "uri"

module Dommy
  module Rack
    # In-process WebSocket transport: connects a page's `new WebSocket(url)`
    # to the Rack app ITSELF, the same way fetch/XHR resolve through the app.
    # The server side receives a real RFC 6455 upgrade request and a real
    # socket (one end of a socketpair, handed over via `rack.hijack`), so
    # ActionCable's full stack runs unmodified — connection auth sees the
    # session's cookies, the origin check sees the session's origin, and the
    # cable event loop reads/writes actual WebSocket frames.
    #
    # The client side of the protocol lives here: frame semantics over the
    # WebSocketFrame codec (text/close/ping handling; ActionCable messages are
    # single-frame text) plus a reader thread that parses server frames and
    # marshals them onto the page thread via `scheduler.post_external`, where
    # they fire the WebSocket's open/message/close events. `settle` /
    # `advance_time` deliver them, like any other external completion.
    #
    # Lifetime: a transport belongs to the page (realm) that opened it; the
    # session closes all live transports on dispose. Note that ActionCable
    # sends its JSON pings on REAL time (an every-3s event-loop timer), not
    # the page's virtual clock — harmless for tests, which settle on the
    # subscription/broadcast messages they wait for.
    class WebSocketTransport
      # Resolve `url` for the connector: an absolute ws(s) URL (http(s) is
      # accepted and treated the same) that is same-origin with `base`.
      # Returns the URI, or nil (the WebSocket then falls back to the
      # in-memory stub).
      def self.rack_target(url, base:)
        target = URI.join(base.to_s, url.to_s)
        scheme = {"ws" => "http", "wss" => "https"}[target.scheme] || target.scheme
        return nil unless %w[http https].include?(scheme)

        b = URI.parse(base.to_s)
        return nil unless b.host == target.host && b.port == target.port

        target.scheme = scheme
        # Re-parse so the return value is a URI::HTTP(S), not a URI::WS whose
        # scheme string was swapped (URI classes compare by class + value).
        URI.parse(target.to_s)
      rescue URI::Error
        nil
      end

      def initialize(app:, ws:, scheduler:, url:, origin:, cookie_string: "")
        @ws = ws
        @scheduler = scheduler
        @url = url
        @write_mutex = Mutex.new
        @sent_close = false
        @closed = false

        @client_io, server_io = ::Socket.pair(:UNIX, :STREAM)
        env = handshake_env(url, origin, cookie_string, server_io)
        status, _headers, _body = app.call(env)
        if env["rack.hijack_io"].nil? && status != -1
          # The app answered with a normal HTTP response (no cable mounted at
          # this path, or the upgrade was rejected): fail like a browser —
          # error then close, deferred so `onerror` handlers attach first.
          fail_connection
        else
          @reader = Thread.new { run_reader }
        end
      end

      # --- API the WebSocket delegates to (page thread) ---

      def send_text(data)
        write_frame(WebSocketFrame::TEXT, data.b)
      end

      def close(code = 1000, reason = "")
        send_close_frame(code == 1005 ? 1000 : code, reason)
      end

      # Hard teardown (session dispose): drop the socket; the reader thread
      # exits on EOF. Safe to call repeatedly.
      def dispose
        @closed = true
        @client_io&.close unless @client_io&.closed?
        @reader&.join(1)
      rescue IOError
        nil
      end

      private

      def handshake_env(url, origin, cookie_string, server_io)
        env = {
          "REQUEST_METHOD" => "GET",
          "SCRIPT_NAME" => "",
          "PATH_INFO" => url.path.empty? ? "/" : url.path,
          "QUERY_STRING" => url.query.to_s,
          "SERVER_NAME" => url.host,
          "SERVER_PORT" => url.port.to_s,
          "HTTP_HOST" => Url.http_host(url),
          "HTTP_UPGRADE" => "websocket",
          "HTTP_CONNECTION" => "Upgrade",
          "HTTP_SEC_WEBSOCKET_KEY" => SecureRandom.base64(16),
          "HTTP_SEC_WEBSOCKET_VERSION" => "13",
          "HTTP_ORIGIN" => origin,
          "REMOTE_ADDR" => "127.0.0.1",
          "rack.url_scheme" => url.scheme,
          "rack.input" => StringIO.new(""),
          "rack.errors" => $stderr,
          "rack.multithread" => true,
          "rack.multiprocess" => false,
          "rack.run_once" => false,
          "rack.hijack?" => true,
        }
        env["HTTP_COOKIE"] = cookie_string unless cookie_string.to_s.empty?
        env["rack.hijack"] = proc { env["rack.hijack_io"] = server_io }
        env
      end

      def fail_connection
        @closed = true
        @client_io.close
        @scheduler.queue_microtask(proc do
          @ws.__transport_error__
          @ws.__transport_closed__(1006, "", was_clean: false)
        end)
      end

      # --- Reader thread ---

      def run_reader
        protocol = read_handshake_response!
        post { @ws.__transport_open__(protocol) }
        read_frames
      rescue HandshakeFailed
        post { @ws.__transport_error__ }
        post { @ws.__transport_closed__(1006, "", was_clean: false) }
      rescue IOError, EOFError, Errno::ECONNRESET, Errno::EPIPE
        post { @ws.__transport_closed__(1006, "", was_clean: false) } unless @closed
      ensure
        @client_io.close rescue nil
      end

      class HandshakeFailed < StandardError; end

      # Read the server's HTTP response head; only `101 Switching Protocols`
      # continues (the handshake accept hash is not re-verified — the server
      # is the app under test, not an untrusted peer). Returns the selected
      # subprotocol, if any.
      def read_handshake_response!
        head = +""
        head << WebSocketFrame.read_exact(@client_io, 1) until head.end_with?("\r\n\r\n")
        raise HandshakeFailed unless head.start_with?("HTTP/1.1 101")

        head[/^sec-websocket-protocol:\s*(\S+)/i, 1]
      end

      def read_frames
        loop do
          opcode, payload = WebSocketFrame.read(@client_io)

          case opcode
          when WebSocketFrame::TEXT, WebSocketFrame::BINARY # continuation frames unsupported: cable messages are single-frame
            data = opcode == WebSocketFrame::TEXT ? payload.force_encoding(Encoding::UTF_8) : payload
            post { @ws.__transport_message__(data) }
          when WebSocketFrame::CLOSE # complete the handshake, then report
            code, reason = WebSocketFrame.parse_close(payload)
            send_close_frame(code == 1005 ? 1000 : code, "")
            @closed = true
            post { @ws.__transport_closed__(code, reason, was_clean: true) }
            break
          when WebSocketFrame::PING
            write_frame(WebSocketFrame::PONG, payload)
          end
        end
      end

      # --- Frame writing (page thread and reader thread; mutex-guarded) ---

      def send_close_frame(code, reason)
        return if @sent_close

        @sent_close = true
        write_frame(WebSocketFrame::CLOSE, WebSocketFrame.close_payload(code, reason))
      end

      def write_frame(opcode, payload)
        frame = WebSocketFrame.client_frame(opcode, payload)
        @write_mutex.synchronize do
          return if @client_io.closed?

          @client_io.write(frame)
        end
      rescue IOError, Errno::EPIPE
        nil
      end

      def post(&block)
        @scheduler.post_external(&block)
      end
    end
  end
end
