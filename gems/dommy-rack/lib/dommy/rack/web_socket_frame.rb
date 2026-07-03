# frozen_string_literal: true

require "securerandom"

module Dommy
  module Rack
    # RFC 6455 frame codec — the byte layout only, no I/O lifecycle. Encodes
    # client frames (masked, per §5.3) and decodes server frames from a
    # blocking IO. WebSocketTransport owns the socket, threads, and what each
    # opcode means; this module owns how a frame is laid out on the wire.
    module WebSocketFrame
      module_function

      TEXT = 0x1
      BINARY = 0x2
      CLOSE = 0x8
      PING = 0x9
      PONG = 0xA

      # Read one frame from `io`. Returns [opcode, payload] with the payload
      # unmasked. Raises EOFError when the stream ends mid-frame.
      def read(io)
        b1, b2 = read_exact(io, 2).unpack("C2")
        opcode = b1 & 0x0f
        length = b2 & 0x7f
        length = read_exact(io, 2).unpack1("n") if length == 126
        length = read_exact(io, 8).unpack1("Q>") if length == 127
        mask = (b2 & 0x80).positive? ? read_exact(io, 4) : nil
        payload = length.zero? ? +"" : read_exact(io, length)
        payload = xor_mask(payload, mask) if mask
        [opcode, payload]
      end

      # A single client frame: FIN + opcode, then the length with the mask
      # bit set (clients MUST mask; RFC 6455 §5.3), the 4-byte key, and the
      # masked payload.
      def client_frame(opcode, payload)
        header = [0x80 | opcode].pack("C")
        length = payload.bytesize
        header <<
          if length < 126 then [0x80 | length].pack("C")
          elsif length < 65_536 then [0x80 | 126, length].pack("Cn")
          else [0x80 | 127, length].pack("CQ>")
          end
        key = SecureRandom.bytes(4)
        header + key + xor_mask(payload, key)
      end

      # The body of a close frame: 2-byte status code + UTF-8 reason.
      def close_payload(code, reason)
        [code].pack("n") + reason.to_s.b
      end

      # [code, reason] from a close frame's payload; an empty payload means
      # "no status received" (1005).
      def parse_close(payload)
        code = payload.bytesize >= 2 ? payload[0, 2].unpack1("n") : 1005
        reason = payload.byteslice(2..).to_s.force_encoding(Encoding::UTF_8)
        [code, reason]
      end

      def read_exact(io, n)
        data = +""
        while data.bytesize < n
          chunk = io.read(n - data.bytesize)
          raise EOFError, "connection closed" if chunk.nil?

          data << chunk
        end
        data
      end

      # XOR (un)masking — its own inverse, so one helper serves both sides.
      def xor_mask(payload, key)
        bytes = payload.bytes
        key_bytes = key.bytes
        bytes.each_index { |i| bytes[i] ^= key_bytes[i % 4] }
        bytes.pack("C*")
      end
    end
  end
end
