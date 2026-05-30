# frozen_string_literal: true

module Dommy
  module Internal
    # A WHATWG URL Standard "basic URL parser" (https://url.spec.whatwg.org/).
    #
    # Replaces the previous Ruby `URI`-based resolution, which diverged from the
    # spec on empty userinfo, relative resolution against opaque/special bases,
    # port-range validation, leading-colon inputs, and percent-encoding. Produces
    # a `Record` (the spec's "URL record"); `Dommy::URL` wraps it.
    module UrlParser
      module_function

      # scheme => default port (file has none).
      SPECIAL = {"ftp" => 21, "file" => nil, "http" => 80, "https" => 443, "ws" => 80, "wss" => 443}.freeze

      # Raised on a parse failure; `URL.new` maps it to DOMException::SyntaxError,
      # `URL.parse` rescues it and returns nil.
      class Failure < StandardError; end

      # The spec URL record. `path` is an Array of segments for a hierarchical
      # URL, or a String for an "opaque path" (cannot-be-a-base) URL. `host` is
      # the already-serialized host string (IPv6 stored with brackets), or nil.
      Record = Struct.new(:scheme, :username, :password, :host, :port, :path, :query, :fragment) do
        def special? = SPECIAL.key?(scheme)
        def opaque_path? = path.is_a?(String)
        def includes_credentials? = !username.to_s.empty? || !password.to_s.empty?
        def default_port = SPECIAL[scheme]
      end

      def parse(input, base_input = nil)
        base = nil
        if base_input && base_input != ""
          base = base_input.is_a?(Record) ? base_input : run(base_input.to_s, nil)
        end
        run(input.to_s, base)
      end

      # ===== percent-encode sets =====

      def c0?(cp) = cp <= 0x1F || cp > 0x7E
      def fragment_set?(cp) = c0?(cp) || [0x20, 0x22, 0x3C, 0x3E, 0x60].include?(cp)
      def query_set?(cp) = c0?(cp) || [0x20, 0x22, 0x23, 0x3C, 0x3E].include?(cp)
      def special_query_set?(cp) = query_set?(cp) || cp == 0x27
      def path_set?(cp) = query_set?(cp) || [0x3F, 0x5E, 0x60, 0x7B, 0x7D].include?(cp)
      def userinfo_set?(cp) = path_set?(cp) || [0x2F, 0x3A, 0x3B, 0x3D, 0x40, 0x5B, 0x5C, 0x5D, 0x7C].include?(cp)

      # UTF-8 percent-encode a single code point against `set` (a predicate).
      def pe(char, set)
        return char unless set.call(char.ord)

        char.b.bytes.map { |b| format("%%%02X", b) }.join
      end

      def percent_decode(str)
        out = +"".b
        bytes = str.b
        i = 0
        while i < bytes.bytesize
          b = bytes.getbyte(i)
          if b == 0x25 && i + 2 < bytes.bytesize &&
              bytes.byteslice(i + 1, 2) =~ /\A[0-9A-Fa-f]{2}\z/
            out << bytes.byteslice(i + 1, 2).to_i(16)
            i += 3
          else
            out << b
            i += 1
          end
        end
        out
      end

      # ===== host parsing =====

      FORBIDDEN_HOST = [0x00, 0x09, 0x0A, 0x0D, 0x20, 0x23, 0x2F, 0x3A, 0x3C, 0x3E,
                        0x3F, 0x40, 0x5B, 0x5C, 0x5D, 0x5E, 0x7C].freeze

      def forbidden_host?(cp) = FORBIDDEN_HOST.include?(cp)
      def forbidden_domain?(cp) = forbidden_host?(cp) || cp <= 0x1F || cp == 0x25 || cp == 0x7F

      def parse_host(input, special)
        if input.start_with?("[")
          raise Failure, "unclosed IPv6 address" unless input.end_with?("]")

          return "[#{parse_ipv6(input[1...-1])}]"
        end
        return parse_opaque_host(input) unless special
        raise Failure, "empty host" if input.empty?

        # UTF-8-decode-without-BOM the percent-decoded bytes: malformed
        # sequences become U+FFFD (which domain-to-ASCII then rejects),
        # matching the spec rather than crashing on invalid encoding.
        domain = percent_decode(input).force_encoding("UTF-8").scrub("�")
        ascii =
          begin
            IDNA.to_ascii(domain, check_hyphens: false, verify_dns_length: false)
          rescue IDNA::Error, Punycode::Error => e
            raise Failure, "domain to ASCII: #{e.message}"
          end
        raise Failure, "empty domain" if ascii.empty?
        raise Failure, "forbidden domain code point" if ascii.each_char.any? { |ch| forbidden_domain?(ch.ord) }

        if ends_in_number?(ascii)
          ip = Ipv4Parser.parse(ascii)
          raise Failure, "invalid IPv4 address" if ip.nil?

          return ip
        end
        ascii
      end

      def parse_opaque_host(input)
        raise Failure, "forbidden host code point" if input.each_char.any? { |ch| forbidden_host?(ch.ord) }

        input.each_char.map { |ch| pe(ch, method(:c0?)) }.join
      end

      def ends_in_number?(input)
        parts = input.split(".", -1)
        parts.pop if parts.length > 1 && parts.last == ""
        return false if parts.empty?

        last = parts.last
        return false if last.empty?
        return true if last.match?(/\A[0-9]+\z/)

        last.match?(/\A0[xX][0-9A-Fa-f]*\z/)
      end

      # WHATWG IPv6 parser -> compressed serialized string (no brackets).
      def parse_ipv6(input)
        address = [0, 0, 0, 0, 0, 0, 0, 0]
        piece_index = 0
        compress = nil
        chars = input.chars
        ptr = 0
        c = ->(i) { i < chars.length ? chars[i] : nil }

        if c.call(ptr) == ":"
          raise Failure, "IPv6 starts with single colon" unless c.call(ptr + 1) == ":"

          ptr += 2
          piece_index += 1
          compress = piece_index
        end

        while c.call(ptr)
          raise Failure, "too many IPv6 pieces" if piece_index == 8

          if c.call(ptr) == ":"
            raise Failure, "multiple IPv6 compressions" unless compress.nil?

            ptr += 1
            piece_index += 1
            compress = piece_index
            next
          end

          value = 0
          length = 0
          while length < 4 && c.call(ptr)&.match?(/[0-9A-Fa-f]/)
            value = value * 16 + c.call(ptr).to_i(16)
            ptr += 1
            length += 1
          end

          if c.call(ptr) == "."
            raise Failure, "IPv4-in-IPv6 with no digits" if length.zero?

            ptr -= length
            raise Failure, "too few pieces for embedded IPv4" if piece_index > 6

            numbers_seen = 0
            while c.call(ptr)
              ipv4_piece = nil
              if numbers_seen.positive?
                if c.call(ptr) == "." && numbers_seen < 4
                  ptr += 1
                else
                  raise Failure, "invalid embedded IPv4"
                end
              end
              raise Failure, "invalid embedded IPv4 digit" unless c.call(ptr)&.match?(/[0-9]/)

              while c.call(ptr)&.match?(/[0-9]/)
                number = c.call(ptr).to_i
                if ipv4_piece.nil?
                  ipv4_piece = number
                elsif ipv4_piece.zero?
                  raise Failure, "leading zero in embedded IPv4"
                else
                  ipv4_piece = ipv4_piece * 10 + number
                end
                raise Failure, "embedded IPv4 piece > 255" if ipv4_piece > 255

                ptr += 1
              end
              address[piece_index] = address[piece_index] * 0x100 + ipv4_piece
              numbers_seen += 1
              piece_index += 1 if numbers_seen == 2 || numbers_seen == 4
            end
            raise Failure, "incomplete embedded IPv4" unless numbers_seen == 4

            break
          elsif c.call(ptr) == ":"
            ptr += 1
            raise Failure, "trailing colon in IPv6" if c.call(ptr).nil?
          elsif c.call(ptr)
            raise Failure, "invalid IPv6 code point"
          end

          address[piece_index] = value
          piece_index += 1
        end

        if compress
          swaps = piece_index - compress
          piece_index = 7
          while piece_index != 0 && swaps.positive?
            address[piece_index], address[compress + swaps - 1] = address[compress + swaps - 1], address[piece_index]
            piece_index -= 1
            swaps -= 1
          end
        elsif piece_index != 8
          raise Failure, "too few IPv6 pieces"
        end

        serialize_ipv6(address)
      end

      def serialize_ipv6(pieces)
        # Find the longest run (length > 1) of zero pieces to compress.
        best_start = nil
        best_len = 0
        i = 0
        while i < 8
          if pieces[i].zero?
            j = i
            j += 1 while j < 8 && pieces[j].zero?
            if (j - i) > best_len
              best_len = j - i
              best_start = i
            end
            i = j
          else
            i += 1
          end
        end
        best_start = nil if best_len < 2

        out = +""
        i = 0
        while i < 8
          if best_start == i
            out << (i.zero? ? "::" : ":")
            i += best_len
            next
          end
          out << pieces[i].to_s(16)
          out << ":" if i < 7
          i += 1
        end
        out
      end

      # ===== serialization =====

      def serialize_path(record)
        return record.path if record.opaque_path?

        record.path.map { |seg| "/#{seg}" }.join
      end

      def serialize(record, exclude_fragment: false)
        out = +"#{record.scheme}:"
        if record.host
          out << "//"
          if record.includes_credentials?
            out << record.username
            out << ":#{record.password}" unless record.password.empty?
            out << "@"
          end
          out << record.host
          out << ":#{record.port}" if record.port
        elsif !record.opaque_path? && record.path.is_a?(Array) &&
            record.path.length > 1 && record.path[0] == ""
          out << "/."
        end
        out << serialize_path(record)
        out << "?#{record.query}" if record.query
        out << "##{record.fragment}" if record.fragment && !exclude_fragment
        out
      end

      # ===== helpers for path normalization =====

      def windows_drive_letter?(seg) = seg.length == 2 && seg[0].match?(/[A-Za-z]/) && [":", "|"].include?(seg[1])
      def normalized_windows_drive_letter?(seg) = seg.length == 2 && seg[0].match?(/[A-Za-z]/) && seg[1] == ":"
      def starts_with_windows_drive_letter?(s)
        s.length >= 2 && s[0].match?(/[A-Za-z]/) && [":", "|"].include?(s[1]) &&
          (s.length == 2 || ["/", "\\", "?", "#"].include?(s[2]))
      end

      def single_dot?(seg) = [".", "%2e"].include?(seg.downcase)

      def double_dot?(seg)
        ["..", ".%2e", "%2e.", "%2e%2e"].include?(seg.downcase)
      end

      def shorten_path(record)
        path = record.path
        return if path.empty?
        return if record.scheme == "file" && path.length == 1 && normalized_windows_drive_letter?(path[0])

        path.pop
      end

      # ===== the basic URL parser state machine =====

      def run(input, base)
        input = input.dup
        # Strip leading/trailing C0 controls and spaces, then remove all
        # ASCII tab/newline.
        input = input.sub(/\A[\x00-\x20]+/, "").sub(/[\x00-\x20]+\z/, "")
        input = input.gsub(/[\t\n\r]/, "")

        chars = input.chars
        len = chars.length
        state = :scheme_start
        url = Record.new("", "", "", nil, nil, [], nil, nil)
        buffer = +""
        at_sign_seen = false
        inside_brackets = false
        password_token_seen = false
        ptr = 0

        cp = lambda { ptr < len ? chars[ptr] : nil }

        loop do
          c = cp.call

          case state
          when :scheme_start
            if c&.match?(/[A-Za-z]/)
              buffer << c.downcase
              state = :scheme
            else
              state = :no_scheme
              next # reprocess (do not advance)
            end

          when :scheme
            if c&.match?(/[A-Za-z0-9+\-.]/)
              buffer << c.downcase
            elsif c == ":"
              url.scheme = buffer
              buffer = +""
              if url.scheme == "file"
                state = :file
              elsif url.special? && base && base.scheme == url.scheme
                state = :special_relative_or_authority
              elsif url.special?
                state = :special_authority_slashes
              elsif input[(ptr + 1)..].to_s.start_with?("/")
                state = :path_or_authority
                ptr += 1
              else
                url.path = ""
                state = :opaque_path
              end
            else
              buffer = +""
              state = :no_scheme
              ptr = -1 # restart from 0 (advance makes it 0)
            end

          when :no_scheme
            raise Failure, "missing scheme" if base.nil? || (base.opaque_path? && c != "#")

            if base.opaque_path? && c == "#"
              url.scheme = base.scheme
              url.path = base.path
              url.query = base.query
              url.fragment = +""
              state = :fragment
            elsif base.scheme != "file"
              state = :relative
              next
            else
              state = :file
              next
            end

          when :special_relative_or_authority
            if c == "/" && input[(ptr + 1)..].to_s.start_with?("/")
              state = :special_authority_ignore_slashes
              ptr += 1
            else
              state = :relative
              next
            end

          when :path_or_authority
            if c == "/"
              state = :authority
            else
              state = :path
              next
            end

          when :relative
            url.scheme = base.scheme
            if c == "/"
              state = :relative_slash
            elsif url.special? && c == "\\"
              state = :relative_slash
            else
              url.username = base.username
              url.password = base.password
              url.host = base.host
              url.port = base.port
              url.path = base.path.dup
              url.query = base.query
              if c == "?"
                url.query = +""
                state = :query
              elsif c == "#"
                url.fragment = +""
                state = :fragment
              elsif c
                url.query = nil
                shorten_path(url)
                state = :path
                next
              end
            end

          when :relative_slash
            if url.special? && (c == "/" || c == "\\")
              state = :special_authority_ignore_slashes
            elsif c == "/"
              state = :authority
            else
              url.username = base.username
              url.password = base.password
              url.host = base.host
              url.port = base.port
              state = :path
              next
            end

          when :special_authority_slashes
            if c == "/" && input[(ptr + 1)..].to_s.start_with?("/")
              state = :special_authority_ignore_slashes
              ptr += 1
            else
              state = :special_authority_ignore_slashes
              next
            end

          when :special_authority_ignore_slashes
            if c != "/" && c != "\\"
              state = :authority
              next
            end

          when :authority
            if c == "@"
              buffer = "%40#{buffer}" if at_sign_seen
              at_sign_seen = true
              buffer.each_char do |ch|
                if ch == ":" && !password_token_seen
                  password_token_seen = true
                  next
                end
                encoded = pe(ch, method(:userinfo_set?))
                if password_token_seen
                  url.password += encoded
                else
                  url.username += encoded
                end
              end
              buffer = +""
            elsif c.nil? || ["/", "?", "#"].include?(c) || (url.special? && c == "\\")
              raise Failure, "empty host with credentials" if at_sign_seen && buffer.empty?

              ptr -= (buffer.length + 1)
              buffer = +""
              state = :host
            else
              buffer << c
            end

          when :host, :hostname
            if c == ":" && !inside_brackets
              raise Failure, "empty host" if buffer.empty?

              url.host = parse_host(buffer, url.special?)
              buffer = +""
              state = :port
            elsif c.nil? || ["/", "?", "#"].include?(c) || (url.special? && c == "\\")
              ptr -= 1
              raise Failure, "empty special host" if url.special? && buffer.empty?

              url.host = parse_host(buffer, url.special?)
              buffer = +""
              state = :path_start
            else
              inside_brackets = true if c == "["
              inside_brackets = false if c == "]"
              buffer << c
            end

          when :port
            if c&.match?(/[0-9]/)
              buffer << c
            elsif c.nil? || ["/", "?", "#"].include?(c) || (url.special? && c == "\\")
              unless buffer.empty?
                port = buffer.to_i
                raise Failure, "port out of range" if port > 65_535

                url.port = (port == url.default_port ? nil : port)
                buffer = +""
              end
              state = :path_start
              next
            else
              raise Failure, "invalid port"
            end

          when :file
            url.scheme = "file"
            url.host = ""
            if c == "/" || c == "\\"
              state = :file_slash
            elsif base && base.scheme == "file"
              url.host = base.host
              url.path = base.path.dup
              url.query = base.query
              if c == "?"
                url.query = +""
                state = :query
              elsif c == "#"
                url.fragment = +""
                state = :fragment
              elsif c
                url.query = nil
                shorten_path(url) unless starts_with_windows_drive_letter?(input[ptr..].to_s)
                url.path = [] if starts_with_windows_drive_letter?(input[ptr..].to_s)
                state = :path
                next
              end
            else
              state = :path
              next
            end

          when :file_slash
            if c == "/" || c == "\\"
              state = :file_host
            else
              if base && base.scheme == "file"
                url.host = base.host
                if !starts_with_windows_drive_letter?(input[ptr..].to_s) &&
                    base.path[0] && normalized_windows_drive_letter?(base.path[0])
                  url.path << base.path[0]
                end
              end
              state = :path
              next
            end

          when :file_host
            if c.nil? || ["/", "\\", "?", "#"].include?(c)
              ptr -= 1
              if buffer.match?(/\A[A-Za-z][:|]\z/)
                state = :path
              elsif buffer.empty?
                url.host = ""
                state = :path_start
              else
                host = parse_host(buffer, true)
                host = "" if host == "localhost"
                url.host = host
                buffer = +""
                state = :path_start
              end
            else
              buffer << c
            end

          when :path_start
            if url.special?
              state = :path
              next unless c == "/" || c == "\\"
            elsif c == "?"
              url.query = +""
              state = :query
            elsif c == "#"
              url.fragment = +""
              state = :fragment
            elsif c
              state = :path
              next unless c == "/"
            end

          when :path
            if c.nil? || c == "/" || (url.special? && c == "\\") ||
                c == "?" || c == "#"
              if double_dot?(buffer)
                shorten_path(url)
                url.path << "" unless c == "/" || (url.special? && c == "\\")
              elsif single_dot?(buffer)
                url.path << "" unless c == "/" || (url.special? && c == "\\")
              else
                if url.scheme == "file" && url.path.empty? && windows_drive_letter?(buffer)
                  buffer[1] = ":"
                end
                url.path << buffer
              end
              buffer = +""
              if c == "?"
                url.query = +""
                state = :query
              elsif c == "#"
                url.fragment = +""
                state = :fragment
              end
            else
              buffer << pe(c, method(:path_set?))
            end

          when :opaque_path
            if c == "?"
              url.query = +""
              state = :query
            elsif c == "#"
              url.fragment = +""
              state = :fragment
            elsif c == " "
              # A space is only percent-encoded when it abuts the end of
              # the opaque path (a following `?`/`#`); an interior space
              # stays literal. (Trailing-at-EOF spaces are already gone
              # via the leading/trailing strip.)
              nxt = chars[ptr + 1]
              url.path += (nxt == "?" || nxt == "#") ? "%20" : " "
            elsif c
              url.path += pe(c, method(:c0?))
            end

          when :query
            if c.nil? || c == "#"
              set = url.special? ? method(:special_query_set?) : method(:query_set?)
              url.query += buffer.each_char.map { |ch| pe(ch, set) }.join
              buffer = +""
              if c == "#"
                url.fragment = +""
                state = :fragment
              end
            else
              buffer << c
            end

          when :fragment
            url.fragment += pe(c, method(:fragment_set?)) if c
          end

          break if ptr >= len

          ptr += 1
        end

        url
      end
    end
  end
end
