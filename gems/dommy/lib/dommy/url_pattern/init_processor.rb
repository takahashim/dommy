# frozen_string_literal: true

require_relative "canonicalizer"
require_relative "pattern_parser"

module Dommy
  class URLPattern
    # Turns a URLPatternInit (a Hash of component strings, plus an optional
    # baseURL) into the per-component strings a pattern is compiled from
    # (`type` "pattern") or a URL is matched by (`type` "url"). A component
    # the init leaves out is inherited from the base URL, unless the init
    # names a component that is at least as specific: giving a pathname
    # means the base's search and hash are not wanted, giving a hostname
    # means its port is not.
    #
    # Spec: https://urlpattern.spec.whatwg.org/#urlpatterninit-processing
    module InitProcessor
      COMPONENTS = %w[protocol username password hostname port pathname search hash].freeze

      module_function

      # `defaults` holds a starting value per component, or nil for none;
      # the constructor passes none, matching passes the empty string.
      #
      # Spec: https://urlpattern.spec.whatwg.org/#process-a-urlpatterninit
      def process(init, type, defaults = {})
        result = {}
        COMPONENTS.each do |name|
          result[name] = defaults[name] unless defaults[name].nil?
        end

        base_url = nil
        if init.key?("baseURL")
          begin
            base_url = Internal::UrlParser.parse(init["baseURL"])
          rescue Internal::UrlParser::Failure
            raise Bridge::TypeError, "Invalid base URL #{init["baseURL"].inspect}"
          end

          result["protocol"] = process_base_url_string(base_url.scheme, type) unless init.key?("protocol")
          if type != "pattern" && init.keys.none? { |k| %w[protocol hostname port username].include?(k) }
            result["username"] = process_base_url_string(base_url.username, type)
          end
          if type != "pattern" && init.keys.none? { |k| %w[protocol hostname port username password].include?(k) }
            result["password"] = process_base_url_string(base_url.password, type)
          end
          if init.keys.none? { |k| %w[protocol hostname].include?(k) }
            result["hostname"] = process_base_url_string(base_url.host.to_s, type)
          end
          if init.keys.none? { |k| %w[protocol hostname port].include?(k) }
            result["port"] = base_url.port.nil? ? "" : base_url.port.to_s
          end
          if init.keys.none? { |k| %w[protocol hostname port pathname].include?(k) }
            result["pathname"] = process_base_url_string(Internal::UrlParser.serialize_path(base_url), type)
          end
          if init.keys.none? { |k| %w[protocol hostname port pathname search].include?(k) }
            result["search"] = process_base_url_string(base_url.query.to_s, type)
          end
          if init.keys.none? { |k| %w[protocol hostname port pathname search hash].include?(k) }
            result["hash"] = process_base_url_string(base_url.fragment.to_s, type)
          end
        end

        result["protocol"] = process_protocol(init["protocol"], type) if init.key?("protocol")
        result["username"] = process_username(init["username"], type) if init.key?("username")
        result["password"] = process_password(init["password"], type) if init.key?("password")
        result["hostname"] = process_hostname(init["hostname"], type) if init.key?("hostname")

        result_protocol = result.fetch("protocol", "")
        result["port"] = process_port(init["port"], result_protocol, type) if init.key?("port")

        if init.key?("pathname")
          result["pathname"] = init["pathname"]
          if base_url && !base_url.opaque_path? && !absolute_pathname?(result["pathname"], type)
            base_path = process_base_url_string(Internal::UrlParser.serialize_path(base_url), type)
            slash_index = base_path.rindex("/")
            result["pathname"] = "#{base_path[0..slash_index]}#{result["pathname"]}" if slash_index
          end
          result["pathname"] = process_pathname(result["pathname"], result_protocol, type)
        end

        result["search"] = process_search(init["search"], type) if init.key?("search")
        result["hash"] = process_hash(init["hash"], type) if init.key?("hash")
        result
      end

      # A base URL's component is literal text: in a pattern its special
      # characters have to be escaped.
      def process_base_url_string(input, type)
        return input unless type == "pattern"

        PatternParser.escape_pattern_string(input)
      end

      # Spec: https://urlpattern.spec.whatwg.org/#is-an-absolute-pathname
      def absolute_pathname?(input, type)
        return false if input.empty?
        return true if input[0] == "/"
        return false if type == "url"
        return false if input.length < 2

        (input[0] == "\\" || input[0] == "{") && input[1] == "/"
      end

      def process_protocol(value, type)
        stripped_value = value.sub(/:\z/, "")
        return stripped_value if type == "pattern"

        Canonicalizer.protocol(stripped_value)
      end

      def process_username(value, type)
        return value if type == "pattern"

        Canonicalizer.username(value)
      end

      def process_password(value, type)
        return value if type == "pattern"

        Canonicalizer.password(value)
      end

      def process_hostname(value, type)
        return value if type == "pattern"

        Canonicalizer.hostname(value)
      end

      def process_port(port_value, protocol_value, type)
        return port_value if type == "pattern"

        Canonicalizer.port(port_value, protocol_value)
      end

      # An empty protocol means none was given, and takes the common case:
      # the pathname of a special scheme.
      def process_pathname(pathname_value, protocol_value, type)
        return pathname_value if type == "pattern"

        if protocol_value.empty? || Internal::UrlParser::SPECIAL.key?(protocol_value)
          Canonicalizer.pathname(pathname_value)
        else
          Canonicalizer.opaque_pathname(pathname_value)
        end
      end

      def process_search(value, type)
        stripped_value = value.sub(/\A\?/, "")
        return stripped_value if type == "pattern"

        Canonicalizer.search(stripped_value)
      end

      def process_hash(value, type)
        stripped_value = value.sub(/\A#/, "")
        return stripped_value if type == "pattern"

        Canonicalizer.hash(stripped_value)
      end
    end
  end
end
