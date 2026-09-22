# frozen_string_literal: true

require_relative "../internal/url_parser"

module Dommy
  class URLPattern
    # The encoding callbacks: each takes a piece of fixed text meant for one
    # URL component and returns it the way the URL parser would serialize
    # it, or raises TypeError when the parser would fail. The spec runs the
    # basic URL parser over a dummy URL with a state override for these;
    # here the relevant state's rules are written out, on the parser's own
    # host parsing and percent-encode sets.
    #
    # Spec: https://urlpattern.spec.whatwg.org/#canonicalization
    module Canonicalizer
      module_function

      # Spec: https://urlpattern.spec.whatwg.org/#canonicalize-a-protocol
      def protocol(value)
        return value if value.empty?

        Internal::UrlParser.parse("#{value}://dummy.invalid/").scheme
      rescue Internal::UrlParser::Failure
        raise Bridge::TypeError, "Invalid protocol #{value.inspect}"
      end

      # Spec: https://urlpattern.spec.whatwg.org/#canonicalize-a-username
      def username(value)
        percent_encode(value, :userinfo_set?)
      end

      # Spec: https://urlpattern.spec.whatwg.org/#canonicalize-a-password
      def password(value)
        percent_encode(value, :userinfo_set?)
      end

      # The hostname state with a state override, on a special URL: reading
      # stops at the first `/`, `?`, `#` or `\`, a `:` outside brackets is a
      # failure, and what was read has to host-parse.
      #
      # Spec: https://urlpattern.spec.whatwg.org/#canonicalize-a-hostname
      def hostname(value)
        return value if value.empty?

        buffer = +""
        inside_brackets = false
        strip_tab_and_newline(value).each_char do |c|
          break if ["/", "?", "#", "\\"].include?(c)
          raise Bridge::TypeError, "Invalid hostname #{value.inspect}" if c == ":" && !inside_brackets

          inside_brackets = true if c == "["
          inside_brackets = false if c == "]"
          buffer << c
        end
        raise Bridge::TypeError, "Invalid hostname #{value.inspect}" if buffer.empty?

        Internal::UrlParser.parse_host(buffer, true)
      rescue Internal::UrlParser::Failure
        raise Bridge::TypeError, "Invalid hostname #{value.inspect}"
      end

      # Spec: https://urlpattern.spec.whatwg.org/#canonicalize-an-ipv6-hostname
      def ipv6_hostname(value)
        value.each_char.map do |c|
          unless c.match?(/\A[0-9A-Fa-f\[\]:]\z/)
            raise Bridge::TypeError, "Invalid IPv6 hostname #{value.inspect}"
          end

          c.downcase
        end.join
      end

      # The port state with a state override: the digits up to the first
      # non-digit are the port, none at all or out of range is a failure, and
      # the scheme's default port is the empty string.
      #
      # Spec: https://urlpattern.spec.whatwg.org/#canonicalize-a-port
      def port(port_value, protocol_value = nil)
        return port_value if port_value.empty?

        digits = strip_tab_and_newline(port_value)[/\A[0-9]*/]
        raise Bridge::TypeError, "Invalid port #{port_value.inspect}" if digits.empty?

        number = digits.to_i
        raise Bridge::TypeError, "Invalid port #{port_value.inspect}" if number > 65_535
        return "" if protocol_value && Internal::UrlParser::SPECIAL[protocol_value] == number

        number.to_s
      end

      # The path state on a special URL, run over a piece of a pathname. A
      # piece without a leading slash is parsed behind "/-" so that a leading
      # "." or ".." piece is not resolved against nothing, then the "/-" is
      # taken off again.
      #
      # Spec: https://urlpattern.spec.whatwg.org/#canonicalize-a-pathname
      def pathname(value)
        return value if value.empty?

        leading_slash = value.start_with?("/")
        modified_value = leading_slash ? value : "/-#{value}"
        result = parse_path(strip_tab_and_newline(modified_value))
        leading_slash ? result : result[2..]
      end

      # The opaque path state with a state override: percent-encode C0
      # controls, stop at `?` or `#`, and encode a space only when it sits
      # right before that stop.
      #
      # Spec: https://urlpattern.spec.whatwg.org/#canonicalize-an-opaque-pathname
      def opaque_pathname(value)
        return value if value.empty?

        chars = strip_tab_and_newline(value).chars
        result = +""
        chars.each_with_index do |c, i|
          break if c == "?" || c == "#"

          if c == " "
            following = chars[i + 1]
            result << ((following == "?" || following == "#") ? "%20" : " ")
          else
            result << Internal::UrlParser.pe(c, Internal::UrlParser.method(:c0?))
          end
        end
        result
      end

      # Spec: https://urlpattern.spec.whatwg.org/#canonicalize-a-search
      def search(value)
        percent_encode(strip_tab_and_newline(value), :special_query_set?)
      end

      # Spec: https://urlpattern.spec.whatwg.org/#canonicalize-a-hash
      def hash(value)
        percent_encode(strip_tab_and_newline(value), :fragment_set?)
      end

      # The basic URL parser drops every ASCII tab and newline before it reads
      # anything, with a state override as without one.
      def strip_tab_and_newline(value)
        value.delete("\t\n\r")
      end

      def percent_encode(value, set_name)
        return value if value.empty?

        set = Internal::UrlParser.method(set_name)
        value.each_char.map { |c| Internal::UrlParser.pe(c, set) }.join
      end

      # `input` starts with the slash the path start state consumes. With a
      # state override `?` and `#` are path characters, so only `/`, `\` and
      # the end close a segment.
      def parse_path(input)
        segments = []
        buffer = +""
        chars = input.chars
        path_set = Internal::UrlParser.method(:path_set?)
        index = 1
        loop do
          c = chars[index]
          if c.nil? || c == "/" || c == "\\"
            if Internal::UrlParser.double_dot?(buffer)
              segments.pop
              segments << "" if c.nil?
            elsif Internal::UrlParser.single_dot?(buffer)
              segments << "" if c.nil?
            else
              segments << buffer
            end
            buffer = +""
            break if c.nil?
          else
            buffer << Internal::UrlParser.pe(c, path_set)
          end
          index += 1
        end
        segments.map { |segment| "/#{segment}" }.join
      end
    end
  end
end
