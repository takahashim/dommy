# frozen_string_literal: true

module Dommy
  module Internal
    # What every query method does with its selector argument before anything
    # matches: coerce it per WebIDL, validate it against the grammar, and map
    # the errors a backend raises onto the DOM ones.
    #
    # Matching itself is SelectorMatcher's, and the state pseudo-classes it
    # cannot answer from the tree alone (`:checked`, `:target`) are here because
    # they read live DOM state rather than the selector.

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
    # raising SyntaxError for syntactically invalid selectors. Delegates to the
    # full grammar parser (SelectorParser), which catches the whole Selectors
    # grammar — `[*=v]`, `..x`, `div % p`, unknown pseudo-elements, undeclared
    # namespaces — not just the obvious cases.
    def self.validate_selector!(selector)
      SelectorParser.validate!(selector.to_s)
    end

    # Coerce the JS argument of a query method (querySelector/All) per WebIDL: the
    # selector is a *non-nullable* DOMString, so JS `null` → "null" and
    # `undefined` → "undefined" (which then match `<null>` / `<undefined>` typed
    # elements rather than returning nothing), while a missing argument is a
    # TypeError. Used at every JS dispatch site so the behaviour is uniform.
    def self.css_query_arg!(args)
      raise ::Dommy::Bridge::TypeError, "1 argument required, but only 0 present" if args.empty?

      value = args[0]
      return "null" if value.nil?
      return "undefined" if defined?(::Dommy::Bridge::UNDEFINED) && value.equal?(::Dommy::Bridge::UNDEFINED)

      value
    end

    # Map a backend's selector complaints onto the DOM's:
    # - an "Unregistered function" means a valid pseudo the backend compiled
    #   but can't evaluate (`:active`, `:invalid`, …) → degrade to no match
    #   (returns []),
    # - a backend syntax complaint becomes a DOMException::SyntaxError,
    # - anything else propagates.
    def self.with_selector_errors(selector)
      yield
    rescue ::StandardError => e
      return [] if e.message.include?("Unregistered function")
      raise DOMException::SyntaxError, "'#{selector}' is not a valid selector." if e.message.include?("unexpected")

      raise
    end

    # `:checked`'s checkedness/selectedness is live state, not the attribute:
    # checkbox/radio inputs match on the checked property (which defaults to
    # the attribute), <option> on selectedness.
    def self.checked_state?(element)
      return false unless element

      case element.tag_name
      when "INPUT"
        %w[checkbox radio].include?(element.respond_to?(:type) ? element.type.to_s : "") &&
          element.respond_to?(:checked) && !!element.checked
      when "OPTION"
        element.respond_to?(:selected) && !!element.selected
      else
        false
      end
    end

    # The id referenced by the document's URL fragment (`:target`), or nil when
    # there is no fragment.
    def self.target_id(document)
      view = document.respond_to?(:default_view) ? document.default_view : nil
      loc = view.respond_to?(:location) ? view.location : nil if view
      hash = loc&.__js_get__("hash").to_s
      hash.start_with?("#") && hash.length > 1 ? hash[1..] : nil
    end
  end
end
