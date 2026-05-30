# frozen_string_literal: true

module Dommy
  # `URLPattern` — pattern matching for URL components, modelled on
  # the WICG URLPattern spec. Supports the path-like syntax familiar
  # from Express / Sinatra / React Router:
  #
  #   /users/:id          → captures `id`
  #   /docs/*             → captures the rest of the path as `0`
  #   /api/:version+      → one-or-more segments
  #   /api/:version?      → optional segment
  #
  # Each pattern is compiled per URL component (`protocol` / `username`
  # / `password` / `hostname` / `port` / `pathname` / `search` / `hash`);
  # `test(url)` returns boolean, `exec(url)` returns a result Hash
  # whose `pathname.groups` etc. carry the captured values.
  #
  # Spec: https://urlpattern.spec.whatwg.org/
  class URLPattern
    COMPONENTS = %w[protocol username password hostname port pathname search hash].freeze

    def initialize(init = nil, _base_url = nil)
      @patterns = {}
      input = init.is_a?(Hash) ? init.transform_keys(&:to_s) : {"pathname" => init.to_s}

      COMPONENTS.each do |comp|
        pattern = input[comp]
        @patterns[comp] = pattern ? compile(pattern.to_s) : compile("*")
      end
    end

    def test(input)
      !exec(input).nil?
    end

    def exec(input)
      values = extract_components(input)
      result = {}

      COMPONENTS.each do |comp|
        compiled = @patterns[comp]
        match = compiled[:regex].match(values[comp].to_s)
        return nil unless match

        groups = {}
        compiled[:names].each_with_index do |name, idx|
          groups[name] = match[idx + 1] if name
        end

        result[comp] = {"input" => values[comp].to_s, "groups" => groups}
      end

      result["inputs"] = [input]
      result
    end

    include Bridge::Methods
    js_methods %w[test exec]
    def __js_call__(method, args)
      case method
      when "test"
        test(args[0])
      when "exec"
        exec(args[0])
      end
    end

    private

    def extract_components(input)
      if input.is_a?(Hash)
        h = input.transform_keys(&:to_s)
        COMPONENTS.each_with_object({}) { |c, m| m[c] = h[c].to_s }
      else
        url_string = input.is_a?(URL) ? input.href : input.to_s
        # Bare path / search / hash inputs are accepted: try to parse
        # as a URL; if that fails, treat the whole string as a pathname.
        u = (URL.new(url_string) rescue nil) ||
          URL.new("http://example.test#{url_string.start_with?("/") ? url_string : "/#{url_string}"}")
        {
          "protocol" => u.protocol.sub(/:$/, ""),
          "username" => u.username,
          "password" => u.password,
          "hostname" => u.hostname,
          "port" => u.port,
          "pathname" => u.pathname,
          "search" => u.search.sub(/^\?/, ""),
          "hash" => u.hash.sub(/^#/, "")
        }
      end
    end

    # Compile a URLPattern fragment into a Regexp + ordered capture
    # names. Supported syntax:
    #
    #   *           → match anything (named "0", "1", ...)
    #   :name       → match `[^/]+`
    #   :name+      → match `[^/]+(?:/[^/]+)*`
    #   :name?      → optional
    #
    # Literal chars are regex-escaped. This is a deliberately small
    # subset of the spec — sufficient for typical routing patterns.
    def compile(pattern)
      names = []
      wildcard_idx = 0
      regex_src = +"\\A"
      i = 0

      while i < pattern.length
        c = pattern[i]
        case c
        when "*"
          names << wildcard_idx.to_s
          wildcard_idx += 1
          regex_src << "(.*)"
          i += 1
        when ":"
          name_match = pattern[i + 1..].match(/\A([A-Za-z_][A-Za-z0-9_]*)([?+*]?)/)
          break unless name_match

          name = name_match[1]
          modifier = name_match[2]
          names << name
          regex_src <<
            case modifier
            when "+"
              "([^/]+(?:/[^/]+)*)"
            when "?"
              "([^/]*)"
            when "*"
              "(.*)"
            else
              "([^/]+)"
            end
          i += 1 + name_match[0].length
        else
          regex_src << Regexp.escape(c)
          i += 1
        end
      end

      regex_src << "\\z"
      {regex: Regexp.new(regex_src), names: names}
    end
  end
end
