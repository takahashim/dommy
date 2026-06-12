# frozen_string_literal: true

module Dommy
  module Internal
    # CSS selector validation and sanitization shared by all backends. The
    # custom pseudo-class *evaluation* (`:disabled`/`:enabled`/`:checked`/
    # `:scope`) is backend-specific and lives in each backend adapter (see
    # `Backend.select_all`); what stays here is the backend-independent grammar
    # checking and the backend-safe rewriting that precedes every query.

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
    # full grammar parser (SelectorParser), which catches everything the old
    # heuristic did (empty string, leading combinator, unknown pseudo-class) plus
    # the rest of the Selectors grammar (`[*=v]`, `..x`, `div % p`, unknown
    # pseudo-elements, undeclared namespaces, …) that Nokogiri silently accepts.
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
      # First drop clauses whose subject is a pseudo-element (`::before`,
      # `:first-line`) — they match no element, and the backend can't compile
      # `::`. Then normalise two valid-but-backend-unfriendly forms before the
      # escaped-colon handling: a trailing unclosed `[`/`(` (CSS closes these at
      # EOF) and namespace prefixes (`*|attr`, `|el` — in an HTML document every
      # node/attribute is in the null namespace, so the prefix is matched away).
      s = SelectorParser.matchable_selector(selector.to_s)
      s = strip_namespace_prefixes(close_open_brackets(s))
      # `:visited` never matches without browsing history (which Dommy doesn't
      # model), so reduce it to a never-match — and, as a bonus, drop the
      # dependency on a backend that can't compile `:visited` (lexbor) while
      # `:link` (an unvisited link) is matched normally.
      s = s.gsub(/:visited(?![\w-])/, ":not(*)") if s.include?(":visited")
      # Neither backend's selector engine implements `:lang()` (lexbor registers
      # it but its parse handler is a deliberate fail-stub). Strip it for the
      # backend; the caller post-filters matches with #lang_match? — see the
      # query methods.
      s = s.gsub(LANG_PSEUDO, "") if s =~ /:lang\(/i
      # `:target` (the element referenced by the document's URL fragment) is also
      # unsupported by the backends; strip it and post-filter by id. A bare
      # `:target` collapses to the universal selector.
      if s =~ /:target(?![\w-])/
        s = s.gsub(/:target(?![\w-])/, "")
        s = "*" if s.strip.empty?
      end
      # Both backends treat `:enabled` / `:disabled` as always-true (matching
      # every element, not just disableable form controls), so strip them and
      # post-filter with #enableable?/#form_control_disabled? — see the query
      # methods. A standalone occurrence (`#x :enabled`) becomes the universal
      # selector so the combinator keeps a subject.
      if s =~ ENABLED_DISABLED_PSEUDO
        s = s.gsub(/(^|[\s>+~,(])\s*:(?:enabled|disabled)(?![\w-])/) { "#{Regexp.last_match(1)}*" }
        s = s.gsub(ENABLED_DISABLED_PSEUDO, "")
        s = "*" if s.strip.empty?
      end
      # State pseudo-classes (`:hover` / `:focus` / `:focus-within` /
      # `:focus-visible` / `:checked`) depend on DOM state the backends don't
      # track, so strip them and post-filter against the document's
      # hovered/focused element and the controls' checkedness. The same
      # filter serves querySelector*, Element#matches, and the CSS cascade.
      # (Like :enabled above, an occurrence inside :not() over-simplifies.)
      if s =~ STATE_PSEUDO
        s = s.gsub(/(^|[\s>+~,(])\s*:(?:hover|focus-within|focus-visible|focus|checked)(?![\w-])/) { "#{Regexp.last_match(1)}*" }
        s = s.gsub(STATE_PSEUDO, "")
        s = "*" if s.strip.empty?
      end
      return s unless s.include?('\\') && s.match?(ATTR_ESCAPED_COLON)

      kept = split_selector_list(s).reject { |clause| clause.match?(ATTR_ESCAPED_COLON) }
      kept.empty? ? ":not(*)" : kept.join(", ")
    end

    # The argument of a `:lang(X)` pseudo-class, when the selector has exactly
    # one distinct one (the common `#x:lang(en)` shape); nil when there is none.
    # Multiple distinct languages can't be recovered from the result set alone,
    # so those fall back to the stripped backend selector (which over-matches).
    LANG_PSEUDO = /:lang\(\s*("?)([^)"']*)\1\s*\)/i
    def self.lang_pseudo_value(selector)
      langs = selector.to_s.scan(LANG_PSEUDO).map { |m| m[1].strip.downcase }.reject(&:empty?).uniq
      langs.size == 1 ? langs.first : nil
    end

    # `:lang(x)` matching (BCP47 extended filtering): an element's content
    # language is the value of the nearest `lang` attribute on it or an
    # ancestor, and `:lang(x)` matches when that language equals `x` or begins
    # with `x` + "-" (case-insensitively). No `lang` in the chain → no match.
    def self.lang_match?(backend_node, lang)
      actual = nearest_lang(backend_node)
      return false unless actual

      a = actual.downcase
      a == lang || a.start_with?("#{lang}-")
    end

    # The disableable form-control elements `:enabled` / `:disabled` apply to.
    ENABLEABLE_ELEMENTS = %w[button input select textarea optgroup option fieldset].freeze
    ENABLED_DISABLED_PSEUDO = /:(?:enabled|disabled)(?![\w-])/

    # State pseudo-classes evaluated by post-filter against DOM state
    # (longest alternatives first so :focus doesn't shadow :focus-within).
    STATE_PSEUDO = /:(?:hover|focus-within|focus-visible|focus|checked)(?![\w-])/

    # Run a backend selector evaluation with the shared error policy:
    # - an "Unregistered function" means a valid pseudo the backend compiled
    #   but can't evaluate (`:active`, `:invalid`, …) → degrade to no match
    #   (returns []),
    # - a backend syntax complaint becomes a DOMException::SyntaxError,
    # - anything else propagates.
    def self.with_selector_errors(selector)
      yield
    rescue ::StandardError => e
      return [] if e.message.include?("Unregistered function")

      if (defined?(::Nokogiri::CSS::SyntaxError) && e.is_a?(::Nokogiri::CSS::SyntaxError)) || e.message.include?("unexpected")
        raise DOMException::SyntaxError, "'#{selector}' is not a valid selector."
      end

      raise
    end

    # Whether `selector` uses a pseudo-class the backend can't match and we
    # post-filter (`:lang()`, `:target`, `:enabled` / `:disabled`, and the
    # state pseudo-classes `:hover` / `:focus*` / `:checked`).
    def self.pseudo_post_filtered?(selector)
      s = selector.to_s
      return true unless lang_pseudo_value(s).nil?

      (s =~ /:target(?![\w-])/ || s =~ ENABLED_DISABLED_PSEUDO || s =~ STATE_PSEUDO) ? true : false
    end

    # Filter backend `nodes` (already matched against the stripped selector) by
    # the post-filtered pseudo-classes the selector carries.
    def self.pseudo_post_filter(nodes, selector, document)
      s = selector.to_s
      if (lang = lang_pseudo_value(s))
        nodes = nodes.select { |n| lang_match?(n, lang) }
      end
      if s =~ /:target(?![\w-])/
        tid = target_id(document)
        nodes = tid ? nodes.select { |n| n["id"].to_s == tid } : []
      end
      if s =~ /:enabled(?![\w-])/
        nodes = nodes.select { |n| enableable?(n) && !form_control_disabled?(n) }
      end
      if s =~ /:disabled(?![\w-])/
        nodes = nodes.select { |n| enableable?(n) && form_control_disabled?(n) }
      end
      if s =~ /:hover(?![\w-])/
        hovered = document&.__hovered_element__
        nodes = hovered ? nodes.select { |n| self_or_ancestor_of?(n, hovered, document) } : []
      end
      if s =~ /:focus(?![\w-])/ || s =~ /:focus-visible(?![\w-])/
        focused = document&.__focused_element__
        nodes = focused ? nodes.select { |n| document.wrap_node(n) == focused } : []
      end
      if s =~ /:focus-within(?![\w-])/
        focused = document&.__focused_element__
        nodes = focused ? nodes.select { |n| self_or_ancestor_of?(n, focused, document) } : []
      end
      if s =~ /:checked(?![\w-])/
        nodes = nodes.select { |n| checked_state?(document&.wrap_node(n)) }
      end
      nodes
    end

    # `:hover` matches the hovered element and all its ancestors; same shape
    # for `:focus-within` against the focused element.
    def self.self_or_ancestor_of?(backend_node, target, document)
      element = document.wrap_node(backend_node)
      return false unless element

      element == target || (element.respond_to?(:contains?) && element.contains?(target))
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

    # `:enabled` / `:disabled` apply only to disableable form controls — not to
    # links or any other element, which the backends wrongly match.
    def self.enableable?(backend_node)
      ENABLEABLE_ELEMENTS.include?(backend_node.name.to_s.downcase)
    end

    # A form control is disabled when it carries the `disabled` attribute, or — for
    # an <option> — its containing <optgroup> is disabled. (The disabled-<fieldset>
    # descendant propagation is not modeled.)
    def self.form_control_disabled?(backend_node)
      return true unless backend_node["disabled"].nil?

      if backend_node.name.to_s.downcase == "option"
        parent = backend_node.respond_to?(:parent) ? backend_node.parent : nil
        return true if parent.respond_to?(:name) &&
                       parent.name.to_s.downcase == "optgroup" && !parent["disabled"].nil?
      end
      false
    end

    # The id referenced by the document's URL fragment (`:target`), or nil when
    # there is no fragment.
    def self.target_id(document)
      view = document.respond_to?(:default_view) ? document.default_view : nil
      loc = view.respond_to?(:location) ? view.location : nil if view
      hash = loc&.__js_get__("hash").to_s
      hash.start_with?("#") && hash.length > 1 ? hash[1..] : nil
    end

    def self.nearest_lang(backend_node)
      node = backend_node
      while node
        if node.respond_to?(:element?) && node.element?
          v = node["lang"]
          return v if v && !v.to_s.empty?
        end
        node = node.respond_to?(:parent) ? node.parent : nil
      end
      nil
    end

    # Append the closers for any `[`/`(` left open outside a string — CSS
    # tokenizing implicitly closes them at EOF, so `[align="center"` is the valid
    # `[align="center"]`, but the backend selector engines reject the unclosed
    # form. String contents and escapes are skipped.
    def self.close_open_brackets(selector)
      sq = 0
      pr = 0
      quote = nil
      esc = false
      selector.each_char do |ch|
        if esc
          esc = false
        elsif ch == "\\"
          esc = true
        elsif quote
          quote = nil if ch == quote
        elsif ch == '"' || ch == "'"
          quote = ch
        elsif ch == "["
          sq += 1
        elsif ch == "]"
          sq -= 1 if sq.positive?
        elsif ch == "("
          pr += 1
        elsif ch == ")"
          pr -= 1 if pr.positive?
        end
      end
      selector + ("]" * sq) + (")" * pr)
    end

    # Drop CSS namespace prefixes (`*|`, `|`) that precede a type or attribute
    # name. An HTML document has only the HTML / null namespaces, so `*|x`
    # (any namespace) and `|x` (no namespace) both reduce to `x`. Leaves the
    # `|=` attribute matcher and the `||` column combinator intact, and never
    # touches a `|` inside a string.
    def self.strip_namespace_prefixes(selector)
      out = +""
      quote = nil
      esc = false
      chars = selector.chars
      i = 0
      while i < chars.length
        ch = chars[i]
        if esc
          out << ch
          esc = false
        elsif ch == "\\"
          out << ch
          esc = true
        elsif quote
          out << ch
          quote = nil if ch == quote
        elsif ch == '"' || ch == "'"
          quote = ch
          out << ch
        elsif ch == "*" && chars[i + 1] == "|" && chars[i + 2] != "=" && chars[i + 2] != "|"
          i += 1 # skip the `*`; the `|` is handled next iteration
        elsif ch == "|" && chars[i + 1] != "=" && chars[i + 1] != "|" && out[-1] != "|"
          # bare namespace separator — drop it (not `|=`, not `||`)
        else
          out << ch
        end
        i += 1
      end
      out
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
