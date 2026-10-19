# frozen_string_literal: true

require_relative "url_normalizer"

module Dommy
  module Rails
    # Adapts Rails URL normalization to the matcher protocol that
    # Dommy::Internal::ElementMatching's link and form finders accept, so `href:` /
    # `action:` criteria absorb scheme/host, query-parameter order,
    # HTML-escaped `&amp;`, and trailing-slash differences.
    class UrlMatcher
      def initialize(expected)
        @expected = expected
      end

      def matches?(actual)
        case @expected
        when Regexp
          actual.to_s.match?(@expected)
        else
          UrlNormalizer.equal?(@expected, actual)
        end
      end
    end
  end
end
