# frozen_string_literal: true

require_relative "pattern_parser"
require_relative "regexp_translator"

module Dommy
  class URLPattern
    # One URL component of a compiled pattern: the normalized pattern string
    # its getter returns, the Regexp that matches it, the names of the
    # regexp's capturing groups in order, and whether any group is a custom
    # regexp rather than a wildcard.
    #
    # Spec: https://urlpattern.spec.whatwg.org/#component
    class Component
      attr_reader :pattern_string, :regexp, :group_names

      # Spec: https://urlpattern.spec.whatwg.org/#compile-a-component
      def self.compile(input, encoding_callback, options)
        parts = PatternParser.parse(input, options, encoding_callback)
        regexp_source, group_names = PatternParser.regexp_and_names(parts, options)
        translation = RegExpTranslator.translate(regexp_source, ignore_case: options.ignore_case)
        pattern_string = PatternParser.pattern_string(parts, options)
        has_regexp_groups = parts.any? { |part| part.type == "regexp" }
        new(pattern_string, translation, group_names, has_regexp_groups)
      end

      def initialize(pattern_string, translation, group_names, has_regexp_groups)
        @pattern_string = pattern_string
        @regexp = translation.regexp
        @optional_groups = translation.optional_groups
        @group_names = group_names
        @has_regexp_groups = has_regexp_groups
      end

      def has_regexp_groups?
        @has_regexp_groups
      end

      # Spec: https://urlpattern.spec.whatwg.org/#protocol-component-matches-a-special-scheme
      def matches_special_scheme?
        Internal::UrlParser::SPECIAL.each_key.any? { |scheme| @regexp.match?(scheme) }
      end

      # The URLPatternComponentResult for `input`, or nil when the component
      # does not match. A group that did not take part is nil, which includes
      # an optional group that would only have matched the empty string:
      # ECMAScript rejects that iteration where Onigmo captures "".
      #
      # Spec: https://urlpattern.spec.whatwg.org/#create-a-component-match-result
      def match(input)
        match_data = @regexp.match(input)
        return nil unless match_data

        groups = {}
        @group_names.each_with_index do |name, index|
          value = match_data[index + 1]
          value = nil if value == "" && @optional_groups.include?(index + 1)
          groups[name] = value
        end
        {"input" => input, "groups" => groups}
      end
    end
  end
end
