# frozen_string_literal: true

require_relative "url_pattern/canonicalizer"
require_relative "url_pattern/component"
require_relative "url_pattern/constructor_string_parser"
require_relative "url_pattern/init_processor"
require_relative "url_pattern/pattern_parser"
require_relative "url_pattern/regexp_translator"
require_relative "url_pattern/tokenizer"

module Dommy
  # `URLPattern` — matches URLs component by component against patterns in
  # the path-to-regexp syntax: `:name` captures up to the next separator,
  # `*` captures anything, `(regexp)` captures what the regexp allows, and
  # `?` `+` `*` after a group make it optional or repeated.
  #
  #   pattern = Dommy::URLPattern.new({pathname: "/users/:id"})
  #   pattern.test("https://x.test/users/42")                     # => true
  #   pattern.exec("https://x.test/users/42")["pathname"]["groups"] # => {"id" => "42"}
  #
  #   Dommy::URLPattern.new("https://:sub.example.com/:id")        # every component from one string
  #   Dommy::URLPattern.new("/books/:id", "https://example.com")   # relative to a base URL
  #   Dommy::URLPattern.new({pathname: "/A"}, ignore_case: true)
  #
  # A component left out of an init matches anything; one left out of a
  # constructor string takes the base URL's value, or the default port after
  # a hostname. `exec` returns a Hash shaped like URLPatternResult (`inputs`,
  # and per component `input` and `groups`), or nil. The getters return each
  # component's normalized pattern string.
  #
  # Matching runs in Ruby: the spec's ECMAScript regexps go through
  # URLPattern::RegExpTranslator to become Onigmo ones.
  #
  # Spec: https://urlpattern.spec.whatwg.org/
  class URLPattern
    COMPONENTS = InitProcessor::COMPONENTS

    # The empty-string starting values a URL input is matched from: a
    # component the input leaves out is empty, not absent.
    URL_INPUT_DEFAULTS = COMPONENTS.to_h { |name| [name, ""] }.freeze
    private_constant :URL_INPUT_DEFAULTS

    # `new URLPattern(input, baseURL, options)` or `new URLPattern(input,
    # options)` from JavaScript, with WebIDL's overload resolution: a third
    # argument or a primitive second one means the first form.
    def self.from_js(args)
      input = args[0]
      if args.length >= 3 || primitive?(args[1])
        base_url = to_usv_string(args[1])
        options = args[2]
      else
        base_url = nil
        options = args[1]
      end
      new(init_from_js(input), base_url, ignore_case: ignore_case_from_js(options))
    end

    # `input` is a pattern string, a Hash of component pattern strings (with
    # an optional "baseURL"), or a Dommy::URL. `base_url` goes with a string
    # input only.
    def initialize(input = {}, base_url = nil, ignore_case: false)
      input = URLPattern.url_as_init(input) if input.is_a?(URL)
      input = normalize_ruby_init(input) unless input.is_a?(String)
      init = if input.is_a?(String)
        parsed = ConstructorStringParser.parse(input)
        if base_url.nil? && !parsed.key?("protocol")
          raise Bridge::TypeError, "A relative pattern #{input.inspect} needs a base URL"
        end

        parsed["baseURL"] = base_url if base_url
        parsed
      else
        raise Bridge::TypeError, "A base URL goes with a pattern string, not an init" if base_url

        input
      end
      compile(InitProcessor.process(init, "pattern"), ignore_case)
    end

    def protocol
      @protocol.pattern_string
    end

    def username
      @username.pattern_string
    end

    def password
      @password.pattern_string
    end

    def hostname
      @hostname.pattern_string
    end

    def port
      @port.pattern_string
    end

    def pathname
      @pathname.pattern_string
    end

    def search
      @search.pattern_string
    end

    def hash
      @hash.pattern_string
    end

    # Spec: https://urlpattern.spec.whatwg.org/#url-pattern-has-regexp-groups
    def has_regexp_groups?
      components.any?(&:has_regexp_groups?)
    end

    def test(input = {}, base_url = nil)
      !exec(input, base_url).nil?
    end

    # `input` is a URL string, a Hash of component strings (with an optional
    # "baseURL"), or a Dommy::URL; `base_url` goes with a string. Returns the
    # URLPatternResult as a Hash, or nil when a component does not match or
    # the input is not a URL.
    #
    # Spec: https://urlpattern.spec.whatwg.org/#url-pattern-match
    def exec(input = {}, base_url = nil)
      input = input.href if input.is_a?(URL)
      input = normalize_ruby_init(input) unless input.is_a?(String)
      inputs = [input]
      values = if input.is_a?(String)
        url_input_values(input, base_url, inputs)
      else
        raise Bridge::TypeError, "A base URL goes with a URL string, not an init" if base_url

        begin
          InitProcessor.process(input, "url", URL_INPUT_DEFAULTS)
        rescue Bridge::TypeError
          nil
        end
      end
      return nil unless values

      result = {"inputs" => inputs}
      COMPONENTS.each do |name|
        component_result = component(name).match(values[name])
        return nil unless component_result

        result[name] = component_result
      end
      result
    end

    include Bridge::Methods
    js_methods %w[test exec]

    def __js_get__(key)
      case key
      when "protocol", "username", "password", "hostname", "port", "pathname", "search", "hash"
        component(key).pattern_string
      when "hasRegExpGroups"
        has_regexp_groups?
      else
        Bridge::ABSENT
      end
    end

    def __js_call__(method, args)
      input = URLPattern.init_from_js(args[0])
      base_url = args.length >= 2 && !args[1].equal?(Bridge::UNDEFINED) ? URLPattern.to_usv_string(args[1]) : nil
      case method
      when "test"
        test(input, base_url)
      when "exec"
        result = exec(input, base_url)
        result && URLPattern.result_for_js(result)
      end
    end

    # ---- WebIDL conversions for the JS bridge ----------------------------

    # URLPatternInput: a string stays one; undefined, null, a JS object or
    # a URL becomes a URLPatternInit with every member run through
    # USVString. A member that is undefined is not present.
    def self.init_from_js(value)
      return {} if value.nil? || value.equal?(Bridge::UNDEFINED)
      return to_usv_string(value) if primitive?(value)

      source = value.is_a?(URL) ? url_as_init(value) : value
      return {} unless source.is_a?(Hash)

      init = {}
      (COMPONENTS + ["baseURL"]).each do |member|
        next unless source.key?(member)

        member_value = source[member]
        next if member_value.equal?(Bridge::UNDEFINED)

        init[member] = to_usv_string(member_value)
      end
      init
    end

    # A URL converts to a dictionary through its own getters, separators
    # included; the init processing strips the `:`, `?` and `#` again.
    def self.url_as_init(url)
      {
        "protocol" => url.protocol, "username" => url.username, "password" => url.password,
        "hostname" => url.hostname, "port" => url.port, "pathname" => url.pathname,
        "search" => url.search, "hash" => url.hash
      }
    end

    # URLPatternOptions: undefined or null is the default, anything but an
    # object is a TypeError.
    def self.ignore_case_from_js(options)
      return false if options.nil? || options.equal?(Bridge::UNDEFINED)
      raise Bridge::TypeError, "URLPatternOptions must be an object" unless options.is_a?(Hash)

      js_truthy?(options["ignoreCase"])
    end

    def self.primitive?(value)
      value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
    end

    # ToString for the values a bridge hands over, then USVString: a lone
    # surrogate cannot arrive in a Ruby String, so only scrubbing is left.
    def self.to_usv_string(value)
      case value
      when String then value.scrub("\uFFFD")
      when Integer then value.to_s
      when Float then value == value.to_i ? value.to_i.to_s : value.to_s
      when true then "true"
      when false then "false"
      when nil then "null"
      else
        value.equal?(Bridge::UNDEFINED) ? "undefined" : value.to_s
      end
    end

    def self.js_truthy?(value)
      return false if value.nil? || value == false || value.equal?(Bridge::UNDEFINED)
      return false if value == 0 || value == "" # rubocop:disable Style/NumericPredicate
      return false if value.is_a?(Float) && value.nan?

      true
    end

    # A group that did not take part is `undefined` in the result's groups,
    # which a Ruby nil would cross the bridge as `null`.
    def self.result_for_js(result)
      result.to_h do |key, value|
        next [key, value] if key == "inputs"

        groups = value["groups"].transform_values { |group| group.nil? ? Bridge::UNDEFINED : group }
        [key, {"input" => value["input"], "groups" => groups}]
      end
    end

    private

    # A Ruby caller's init: symbol keys are fine, and a nil member is absent.
    def normalize_ruby_init(input)
      raise Bridge::TypeError, "URLPattern input must be a String, a Hash or a URL" unless input.is_a?(Hash)

      init = {}
      input.each do |key, value|
        next if value.nil?

        init[key.to_s] = value.to_s
      end
      init
    end

    # Spec: https://urlpattern.spec.whatwg.org/#url-pattern-create
    def compile(processed_init, ignore_case)
      COMPONENTS.each do |name|
        processed_init[name] = "*" unless processed_init.key?(name)
      end
      default_port = Internal::UrlParser::SPECIAL[processed_init["protocol"]]
      processed_init["port"] = "" if default_port && processed_init["port"] == default_port.to_s

      @protocol = Component.compile(processed_init["protocol"], Canonicalizer.method(:protocol), DEFAULT_OPTIONS)
      @username = Component.compile(processed_init["username"], Canonicalizer.method(:username), DEFAULT_OPTIONS)
      @password = Component.compile(processed_init["password"], Canonicalizer.method(:password), DEFAULT_OPTIONS)
      hostname_callback = ipv6_hostname_pattern?(processed_init["hostname"]) ? :ipv6_hostname : :hostname
      @hostname = Component.compile(processed_init["hostname"], Canonicalizer.method(hostname_callback),
                                    HOSTNAME_OPTIONS)
      @port = Component.compile(processed_init["port"], Canonicalizer.method(:port), DEFAULT_OPTIONS)

      compile_options = Options.new("", "", ignore_case)
      if @protocol.matches_special_scheme?
        pathname_options = Options.new(PATHNAME_OPTIONS.delimiter, PATHNAME_OPTIONS.prefix, ignore_case)
        @pathname = Component.compile(processed_init["pathname"], Canonicalizer.method(:pathname), pathname_options)
      else
        @pathname = Component.compile(processed_init["pathname"], Canonicalizer.method(:opaque_pathname),
                                      compile_options)
      end
      @search = Component.compile(processed_init["search"], Canonicalizer.method(:search), compile_options)
      @hash = Component.compile(processed_init["hash"], Canonicalizer.method(:hash), compile_options)
    end

    # Spec: https://urlpattern.spec.whatwg.org/#hostname-pattern-is-an-ipv6-address
    def ipv6_hostname_pattern?(input)
      return false if input.length < 2
      return true if input[0] == "["

      (input[0] == "{" || input[0] == "\\") && input[1] == "["
    end

    def components
      [@protocol, @username, @password, @hostname, @port, @pathname, @search, @hash]
    end

    def component(name)
      case name
      when "protocol" then @protocol
      when "username" then @username
      when "password" then @password
      when "hostname" then @hostname
      when "port" then @port
      when "pathname" then @pathname
      when "search" then @search
      when "hash" then @hash
      end
    end

    # The component strings of a URL string input, parsed against `base_url`
    # when one is given; nil when either fails to parse. `inputs` gets the
    # base URL string appended, as the result reports it.
    def url_input_values(input, base_url, inputs)
      base = nil
      if base_url
        base = Internal::UrlParser.parse(base_url)
        inputs << base_url
      end
      record = Internal::UrlParser.parse(input, base)
      {
        "protocol" => record.scheme,
        "username" => record.username,
        "password" => record.password,
        "hostname" => record.host.to_s,
        "port" => record.port.nil? ? "" : record.port.to_s,
        "pathname" => Internal::UrlParser.serialize_path(record),
        "search" => record.query.to_s,
        "hash" => record.fragment.to_s
      }
    rescue Internal::UrlParser::Failure
      nil
    end
  end
end
