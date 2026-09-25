# frozen_string_literal: true

require "stringio"

module Dommy
  module Rack
    # In-process Server-Sent Events transport: connects a page's
    # `new EventSource(url)` to the Rack app ITSELF, the same way fetch/XHR and
    # the WebSocket transport resolve through the app. The stream is a normal
    # same-origin GET whose (possibly streaming) response body is read on a
    # reader thread and parsed as `text/event-stream`; every dispatched event is
    # marshalled onto the page thread via `scheduler.post_external`, where it
    # fires the EventSource's open / message / error events.
    #
    # Lifetime: a transport belongs to the page (realm) that opened it; the
    # session closes all live transports on dispose. Unlike WebSockets, SSE
    # has no client-to-server channel, so EventSource#close is the only write.
    class EventSourceTransport
      # Resolve `url` for the connector: an absolute http(s) URL that is
      # same-origin with `base`, or nil (the EventSource then falls back to the
      # in-memory stub).
      def self.rack_target(url, base:)
        target = Dommy::URL.parse(url.to_s, base.to_s)
        return nil unless target
        return nil unless %w[http: https:].include?(target.protocol)

        b = Dommy::URL.parse(base.to_s)
        return nil unless b && b.hostname == target.hostname && b.port == target.port

        target
      end

      def initialize(app:, es:, scheduler:, url:, origin:, cookie_string: "")
        @app = app
        @es = es
        @scheduler = scheduler
        @url = url
        @origin = origin
        @cookie_string = cookie_string
        @closed = false
        @buffer = +""
        @data = nil
        @event = nil
        @id = nil

        @reader = Thread.new { run }
      end

      # Called from the page thread when the EventSource is closed: stop the
      # reader and release the response body.
      def close
        @closed = true
        close_body
        nil
      end

      # Hard teardown (session dispose): drop the stream; the reader exits on
      # the closed body or at the next chunk.
      def dispose
        close
        @reader&.join(1)
      rescue IOError
        nil
      end

      private

      def run
        status, _headers, body = @app.call(env)
        @body = body
        if status >= 400
          post { @es.__transport_error__ }
          return
        end

        post { @es.__transport_open__ }
        body.each { |chunk| feed(chunk) unless @closed }
        post { @es.__transport_closed__ } unless @closed
      rescue IOError, Errno::EPIPE, Errno::ECONNRESET
        nil
      rescue StandardError
        post { @es.__transport_error__ } unless @closed
      ensure
        close_body
      end

      def env
        url = @url
        env = {
          "REQUEST_METHOD" => "GET",
          "SCRIPT_NAME" => "",
          "PATH_INFO" => url.pathname.empty? ? "/" : url.pathname,
          "QUERY_STRING" => url.search.delete_prefix("?"),
          "SERVER_NAME" => url.hostname,
          "SERVER_PORT" => Url.server_port(url),
          "HTTP_HOST" => url.host,
          "HTTP_ACCEPT" => "text/event-stream",
          "HTTP_ORIGIN" => @origin,
          "REMOTE_ADDR" => "127.0.0.1",
          "rack.url_scheme" => url.protocol.delete_suffix(":"),
          "rack.input" => StringIO.new(""),
          "rack.errors" => $stderr,
          "rack.multithread" => true,
          "rack.multiprocess" => false,
          "rack.run_once" => false,
        }
        env["HTTP_COOKIE"] = @cookie_string unless @cookie_string.to_s.empty?
        env
      end

      # --- SSE parsing (the "event stream interpretation" algorithm) ---

      def feed(chunk)
        @buffer << chunk.to_s
        while (newline = @buffer.index("\n"))
          line = @buffer.slice!(0, newline + 1).chomp("\n").chomp("\r")
          if line.empty?
            dispatch_event
          elsif !line.start_with?(":")
            field, value = line.split(":", 2)
            store_field(field, value&.sub(/\A /, ""))
          end
        end
      end

      def store_field(field, value)
        case field
        when "data" then (@data ||= []) << value.to_s
        when "event" then @event = value
        when "id" then @id = value unless value.to_s.include?("\0")
        end
      end

      # A blank line dispatches the buffered block, if it carried data; an
      # id-only / event-only block updates state without firing a message.
      # The values are snapshotted into locals because the post runs later,
      # after the block's own state has been reset (event is per-block).
      def dispatch_event
        return unless @data

        data = @data.join("\n")
        event = @event || "message"
        id = @id
        @data = nil
        @event = nil
        post { @es.__transport_message__(data, event: event, id: id) }
      end

      def close_body
        @body&.close if @body.respond_to?(:close)
      rescue IOError, Errno::EPIPE
        nil
      end

      def post(&block)
        @scheduler.post_external(&block)
      end
    end
  end
end
