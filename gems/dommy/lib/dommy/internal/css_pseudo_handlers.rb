# frozen_string_literal: true

module Dommy
  module Internal
    # Custom Nokogiri pseudo-class handlers so CSS selectors like
    # `:disabled` / `:enabled` / `:checked` work in query_selector(_all).
    # Nokogiri calls the method named after the pseudo-class with the current
    # node list and expects the filtered list back. Receives raw Nokogiri
    # nodes (not Dommy wrappers).
    class CSSPseudoHandlers < BasicObject
      include ::Kernel

      def disabled(list)
        list.find_all { |node| node.has_attribute?("disabled") }
      end

      def enabled(list)
        list.find_all { |node| !node.has_attribute?("disabled") }
      end

      def checked(list)
        list.find_all { |node| node.has_attribute?("checked") }
      end
    end

    CSS_PSEUDO_HANDLERS = CSSPseudoHandlers.new

    # Adds `:scope` support. Nokogiri compiles `:scope` into a custom XPath
    # function `nokogiri:scope(.)`, calling it as `scope(node_set)`; a scoped
    # query (`el.querySelector(":scope > p")`) resolves it to the context
    # element, so only that element matches. One instance per query — it carries
    # the context node.
    class ScopedCSSPseudoHandlers < CSSPseudoHandlers
      def initialize(scope_node)
        @scope_node = scope_node
      end

      def scope(list)
        list.find_all { |node| node.pointer_id == @scope_node.pointer_id }
      end
    end

    def self.scoped_pseudo_handlers(scope_node)
      ScopedCSSPseudoHandlers.new(scope_node)
    end

    # The complete set of CSS pseudo-classes (+ the four legacy single-colon
    # pseudo-elements). A `:identifier` outside this set is an unknown selector
    # token → SyntaxError, whereas a known-but-unimplemented one (`:hover`) is a
    # valid selector that simply matches nothing.
    KNOWN_PSEUDOS = %w[
      active any-link autofill blank checked current default defined disabled empty
      enabled first first-child first-of-type focus focus-visible focus-within
      fullscreen future has host hover in-range indeterminate invalid is lang
      last-child last-of-type left link local-link modal not nth-child nth-col
      nth-last-child nth-last-col nth-last-of-type nth-of-type only-child
      only-of-type optional out-of-range past placeholder-shown playing paused
      read-only read-write required right root scope target target-within
      user-invalid user-valid valid visited where dir
      before after first-line first-letter
    ].to_set.freeze

    # Validate a non-null CSS selector for `querySelector`/`matches`/`closest`,
    # raising SyntaxError for cases Nokogiri silently accepts: the empty string,
    # a selector list beginning with a combinator (a relative selector these
    # methods don't accept), and an unknown pseudo-class.
    def self.validate_selector!(selector)
      s = selector.to_s
      invalid = s.empty? || s.match?(/\A\s*[>+~]/) || unknown_pseudo?(s)
      raise ::Dommy::DOMException::SyntaxError, "'#{s}' is not a valid selector" if invalid

      s
    end

    # True when the selector names a pseudo-class outside KNOWN_PSEUDOS. Only
    # checked for selectors without attribute selectors / strings / escapes,
    # where a bare `:ident` (single colon, not a `::` pseudo-element) is
    # unambiguous; otherwise we defer to the backend.
    def self.unknown_pseudo?(selector)
      return false if selector.match?(/["'\[\\]/)

      selector.scan(/(?<![:\\]):([a-zA-Z][a-zA-Z0-9-]*)/).any? do |(name)|
        !KNOWN_PSEUDOS.include?(name.downcase)
      end
    end

    # Nokogiri's CSS→XPath compiler chokes on an escaped colon INSIDE an
    # attribute selector (`[xlink\:href]`, a namespaced/SVG attribute → "Invalid
    # predicate"), though it handles escaped colons in class/id selectors fine
    # (`.md\:flex`, `#a\:b` — Tailwind). Those attribute selectors target
    # XML-namespaced attributes the HTML backend doesn't model, so drop just the
    # comma-clauses that use them; the rest of the selector list is preserved.
    # (Real frameworks hit this constantly — Turbo's click handler matches
    # `a[href], a[xlink\:href]` on every click.) Returns a backend-safe selector;
    # if every clause was unsupported, returns one that compiles but never
    # matches.
    ATTR_ESCAPED_COLON = /\[[^\]]*\\:[^\]]*\]/
    def self.backend_safe_selector(selector)
      s = selector.to_s
      return s unless s.include?('\\') && s.match?(ATTR_ESCAPED_COLON)

      kept = split_selector_list(s).reject { |clause| clause.match?(ATTR_ESCAPED_COLON) }
      kept.empty? ? ":not(*)" : kept.join(", ")
    end

    # Split a selector list on top-level commas only (commas inside [...], (...),
    # or quotes are part of a single complex selector and must not split it).
    def self.split_selector_list(selector)
      clauses = []
      depth = 0
      quote = nil
      current = +""
      selector.each_char do |ch|
        if quote
          quote = nil if ch == quote
        elsif ch == '"' || ch == "'"
          quote = ch
        elsif ch == "[" || ch == "("
          depth += 1
        elsif ch == "]" || ch == ")"
          depth -= 1 if depth.positive?
        elsif ch == "," && depth.zero?
          clauses << current.strip
          current = +""
          next
        end
        current << ch
      end
      clauses << current.strip
      clauses.reject(&:empty?)
    end
  end
end
