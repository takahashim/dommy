# frozen_string_literal: true

require_relative "tokenizer"

module Dommy
  class URLPattern
    # Splits a URL-shaped pattern string such as "https://:sub.example.com/:id"
    # into a URLPatternInit, one pattern string per component. It walks the
    # pattern's tokens the way the basic URL parser walks characters, so
    # that a `:` or `/` inside a `{group}`, a `(regexp)` or a `:name` never
    # counts as a component boundary. The components it never reaches are
    # left out, and get their defaults later: a wildcard for pathname, search
    # and hash after a component that was given, the default port after a
    # hostname.
    #
    # Spec: https://urlpattern.spec.whatwg.org/#constructor-string-parsing
    class ConstructorStringParser
      def self.parse(input)
        new(input).parse
      end

      def initialize(input)
        @input = input
        @chars = input.chars
        @tokens = Tokenizer.tokenize(input, "lenient")
        @result = {}
        @component_start = 0
        @token_index = 0
        @token_increment = 1
        @group_depth = 0
        @hostname_ipv6_bracket_depth = 0
        @protocol_matches_special_scheme = false
        @state = "init"
      end

      def parse
        while @token_index < @tokens.length
          @token_increment = 1

          if @tokens[@token_index].type == "end"
            if @state == "init"
              # No protocol terminator: a relative pattern, which begins at
              # the hash, the search or the pathname.
              rewind
              if hash_prefix?
                change_state("hash", 1)
              elsif search_prefix?
                change_state("search", 1)
              else
                change_state("pathname", 0)
              end
              @token_index += @token_increment
              next
            end
            if @state == "authority"
              # No "@": there was no username or password after all.
              rewind_and_set_state("hostname")
              @token_index += @token_increment
              next
            end
            change_state("done", 0)
            break
          end

          # Nothing inside a `{…}` grouping can be a component boundary.
          if group_open?
            @group_depth += 1
            @token_index += @token_increment
            next
          end
          if @group_depth.positive?
            if group_close?
              @group_depth -= 1
            else
              @token_index += @token_increment
              next
            end
          end

          run_state
          @token_index += @token_increment
        end

        @result["port"] = "" if @result.key?("hostname") && !@result.key?("port")
        @result
      end

      private

      def run_state
        case @state
        when "init"
          rewind_and_set_state("protocol") if protocol_suffix?
        when "protocol"
          if protocol_suffix?
            compute_protocol_matches_special_scheme_flag
            next_state = "pathname"
            skip = 1
            if next_is_authority_slashes?
              next_state = "authority"
              skip = 3
            elsif @protocol_matches_special_scheme
              next_state = "authority"
            end
            change_state(next_state, skip)
          end
        when "authority"
          if identity_terminator?
            rewind_and_set_state("username")
          elsif pathname_start? || search_prefix? || hash_prefix?
            rewind_and_set_state("hostname")
          end
        when "username"
          if password_prefix?
            change_state("password", 1)
          elsif identity_terminator?
            change_state("hostname", 1)
          end
        when "password"
          change_state("hostname", 1) if identity_terminator?
        when "hostname"
          if ipv6_open?
            @hostname_ipv6_bracket_depth += 1
          elsif ipv6_close?
            @hostname_ipv6_bracket_depth -= 1
          elsif port_prefix? && @hostname_ipv6_bracket_depth.zero?
            change_state("port", 1)
          elsif pathname_start?
            change_state("pathname", 0)
          elsif search_prefix?
            change_state("search", 1)
          elsif hash_prefix?
            change_state("hash", 1)
          end
        when "port"
          if pathname_start?
            change_state("pathname", 0)
          elsif search_prefix?
            change_state("search", 1)
          elsif hash_prefix?
            change_state("hash", 1)
          end
        when "pathname"
          if search_prefix?
            change_state("search", 1)
          elsif hash_prefix?
            change_state("hash", 1)
          end
        when "search"
          change_state("hash", 1) if hash_prefix?
        when "hash"
          nil
        end
      end

      # Close the component being read, fill in the ones that were skipped
      # over on the way to `new_state`, and start reading there.
      def change_state(new_state, skip)
        @result[@state] = make_component_string unless %w[init authority done].include?(@state)

        if @state != "init" && new_state != "done"
          if %w[protocol authority username password].include?(@state) &&
              %w[port pathname search hash].include?(new_state) && !@result.key?("hostname")
            @result["hostname"] = ""
          end
          if %w[protocol authority username password hostname port].include?(@state) &&
              %w[search hash].include?(new_state) && !@result.key?("pathname")
            @result["pathname"] = @protocol_matches_special_scheme ? "/" : ""
          end
          if %w[protocol authority username password hostname port pathname].include?(@state) &&
              new_state == "hash" && !@result.key?("search")
            @result["search"] = ""
          end
        end

        @state = new_state
        @token_index += skip
        @component_start = @token_index
        @token_increment = 0
      end

      def rewind
        @token_index = @component_start
        @token_increment = 0
      end

      def rewind_and_set_state(state)
        rewind
        @state = state
      end

      def safe_token(index)
        return @tokens[index] if index < @tokens.length

        @tokens.last
      end

      # A `value` that is plain text at `index`: a char, an escaped char, or
      # an invalid char, but not part of a name, a regexp or a group.
      def non_special_pattern_char?(index, value)
        token = safe_token(index)
        return false unless token.value == value

        %w[char escaped-char invalid-char].include?(token.type)
      end

      def protocol_suffix?
        non_special_pattern_char?(@token_index, ":")
      end

      def next_is_authority_slashes?
        non_special_pattern_char?(@token_index + 1, "/") && non_special_pattern_char?(@token_index + 2, "/")
      end

      def identity_terminator?
        non_special_pattern_char?(@token_index, "@")
      end

      def password_prefix?
        non_special_pattern_char?(@token_index, ":")
      end

      def port_prefix?
        non_special_pattern_char?(@token_index, ":")
      end

      def pathname_start?
        non_special_pattern_char?(@token_index, "/")
      end

      # A `?` is the search prefix unless it modifies the group before it.
      def search_prefix?
        return true if non_special_pattern_char?(@token_index, "?")
        return false unless @tokens[@token_index].value == "?"

        previous_index = @token_index - 1
        return true if previous_index.negative?

        previous_token = safe_token(previous_index)
        !%w[name regexp close asterisk].include?(previous_token.type)
      end

      def hash_prefix?
        non_special_pattern_char?(@token_index, "#")
      end

      def group_open?
        @tokens[@token_index].type == "open"
      end

      def group_close?
        @tokens[@token_index].type == "close"
      end

      def ipv6_open?
        non_special_pattern_char?(@token_index, "[")
      end

      def ipv6_close?
        non_special_pattern_char?(@token_index, "]")
      end

      # The input from the start of the current component to the current
      # token, as code points.
      def make_component_string
        token = @tokens[@token_index]
        component_start_token = safe_token(@component_start)
        start_index = component_start_token.index
        @chars[start_index...token.index].join
      end

      # The protocol is compiled early: whether it can match a special scheme
      # decides where the authority and the default pathname come from.
      def compute_protocol_matches_special_scheme_flag
        protocol_component = Component.compile(make_component_string, Canonicalizer.method(:protocol),
                                               DEFAULT_OPTIONS)
        @protocol_matches_special_scheme = true if protocol_component.matches_special_scheme?
      end
    end
  end
end
