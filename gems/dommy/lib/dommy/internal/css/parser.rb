# frozen_string_literal: true

require_relative "../selector_parser"
require_relative "../css_source"
require_relative "../css_syntax"
require_relative "custom_properties"

module Dommy
  module Internal
    module CSS
      # The abstraction seam over the CSS stylesheet parser. The only
      # implementation is makiri's lexbor binding
      # (Makiri::Lexbor::CSS.parse_stylesheet) — see css-cascade.md: the
      # tokenizer, error recovery, and specificity all come from lexbor;
      # this module just normalizes its plain-Hash output into structs the
      # cascade layer consumes. CSS parsing is independent of the DOM
      # backend, so this works on the Nokogiri backend too as long as the
      # makiri gem is installed.
      module Parser
        # One comma branch of a selector list. `specificity` is the
        # Selectors L4 [A, B, C] triple computed from Dommy's AST.
        Selector = Struct.new(:text, :ast, :specificity)

        Declaration = Struct.new(:name, :value, :important)

        StyleRule = Struct.new(:selectors, :declarations) do
          def grouping? = false
        end

        # Grouping at-rules (CSS conditional rules): their block contributes
        # its rules to the cascade only when the rule is "active" (RuleIndex
        # decides — @media query matches, @supports condition holds, @layer
        # always). The block is flattened in source order; @layer ordering and
        # @supports/@media precedence beyond source order are out of scope.
        MediaRule = Struct.new(:condition, :rules) do
          def grouping? = true
        end

        # @layer name { ... } — a named (or anonymous, name nil) cascade layer.
        # Its rules always participate; their precedence is decided by layer
        # order (RuleIndex/Cascade), which sits between origin and specificity.
        LayerRule = Struct.new(:name, :rules) do
          def grouping? = true
        end

        # @layer a, b, c; (statement form) or an empty @layer block — declares
        # layer names (and thereby their order) without contributing rules.
        # `names` entries are layer names; nil means an anonymous layer.
        LayerStatement = Struct.new(:names) do
          def grouping? = false
        end

        # @supports (cond) { ... } — its rules participate when `condition`
        # evaluates true (Supports.match?).
        SupportsRule = Struct.new(:condition, :rules) do
          def grouping? = true
        end

        # @scope (start) to (end) { ... } — `start`/`end` are selector-list texts
        # (either may be nil: a missing `start` scopes to the document element,
        # a missing `end` has no lower boundary). RuleIndex resolves the scoping
        # roots and limits and scopes the block's rules to in-scope elements.
        ScopeRule = Struct.new(:start, :end, :rules) do
          def grouping? = true
        end

        # @import url(...) [media] — the referenced sheet's rules are spliced
        # in at this position (RuleIndex resolves the URL through the host).
        # `media` (may be "") gates them like @media.
        ImportRule = Struct.new(:url, :media) do
          def grouping? = false
        end

        module_function

        # Parse a stylesheet into an Array of StyleRule / MediaRule / LayerRule
        # / SupportsRule in source order (other at-rules are ignored). Lexbor's
        # css-syntax-3 error recovery applies; selectors and at-rules it can't
        # parse are surfaced for Dommy to re-validate, not silently dropped.
        def parse(text)
          rules = ::Makiri::Lexbor::CSS.parse_stylesheet(text.to_s)
          normalize_rules(rules, collect_namespaces(rules))
        end

        def normalize_rules(rules, namespaces = {})
          rules.filter_map do |rule|
            case rule[:type]
            when :style
              build_style_rule(normalize_selectors(rule[:selectors], namespaces), rule[:declarations])
            when :bad_style
              # lexbor couldn't parse this selector list (most often a
              # pseudo-element like ::before, which its parser predates).
              # Re-validate the raw prelude with Dommy's Selectors L4 parser:
              # pseudo-element rules survive, genuinely invalid ones drop
              # (normalize_selectors returns []).
              build_style_rule(normalize_selectors([{text: rule[:selector_text]}], namespaces), rule[:declarations])
            when :at_rule
              normalize_at_rule(rule, namespaces)
            end
          end
        end

        # The stylesheet's @namespace prefix => URI map (with :default for the
        # prefixless default namespace), so `svg|rect` resolves when the sheet
        # declared `@namespace svg url(...)`. @namespace is top-level only.
        def collect_namespaces(rules)
          rules.each_with_object({}) do |rule, namespaces|
            next unless rule[:type] == :at_rule && rule[:name].to_s.casecmp("namespace").zero?

            prefix, uri = parse_namespace(rule[:prelude])
            namespaces[prefix.nil? ? :default : prefix] = uri if uri
          end
        end

        # @namespace prelude: `[prefix] (url(uri) | "uri")`. Returns
        # [prefix_or_nil, uri_or_nil].
        def parse_namespace(prelude)
          rest = prelude.to_s.strip
          prefix = nil
          if (match = rest.match(/\A([A-Za-z_][\w-]*)\s+/))
            prefix = match[1]
            rest = rest[match.end(0)..]
          end

          uri =
            if (match = rest.match(/\Aurl\(\s*(.*?)\s*\)\s*\z/i))
              match[1]
            elsif (match = rest.match(/\A(?:"([^"]*)"|'([^']*)')\s*\z/))
              match[1] || match[2]
            end
          [prefix, uri&.gsub(/\A["']|["']\z/, "")&.strip]
        end

        # @media / @layer / @supports become grouping rules the cascade
        # understands; every other at-rule (@font-face, @keyframes, @import,
        # @page, ...) is ignored for now (returning nil drops it from the
        # rule stream, but lexbor still parsed it, so nothing crashes).
        def normalize_at_rule(rule, namespaces = {})
          case rule[:name].to_s.downcase
          when "media"
            MediaRule.new(rule[:prelude], normalize_rules(rule[:rules], namespaces))
          when "layer"
            normalize_layer(rule, namespaces)
          when "supports"
            SupportsRule.new(rule[:prelude], normalize_rules(rule[:rules], namespaces))
          when "scope"
            scope_start, scope_end = parse_scope_prelude(rule[:prelude])
            ScopeRule.new(scope_start, scope_end, normalize_rules(rule[:rules], namespaces))
          when "import"
            parse_import(rule[:prelude])
          end
        end

        # @layer comes in two shapes (lexbor reports both as an at_rule):
        #   block form `@layer name { rules }` — one named/anonymous layer with
        #     content (an empty block carries no rules, like a statement);
        #   statement form `@layer a, b, c;` — declares several layers' order
        #     without content.
        # An empty `rules` means the statement form (or empty block): it only
        # fixes layer order. A nil name (empty prelude) is an anonymous layer.
        def normalize_layer(rule, namespaces)
          names = split_layer_names(rule[:prelude])
          rules = rule[:rules] || []
          if rules.empty?
            LayerStatement.new(names.empty? ? [nil] : names)
          else
            LayerRule.new(names.first, normalize_rules(rules, namespaces))
          end
        end

        # The comma-separated layer names of an @layer prelude ("" → [], so an
        # anonymous layer yields no names).
        def split_layer_names(prelude)
          prelude.to_s.split(",").map(&:strip).reject(&:empty?)
        end

        # @scope prelude: `(<start>) [to (<end>)]`. Returns [start_or_nil,
        # end_or_nil] as selector-list texts (an empty prelude — bare @scope —
        # yields [nil, nil]).
        def parse_scope_prelude(prelude)
          text = prelude.to_s.strip
          return [nil, nil] if text.empty?

          match = text.match(/\A\(\s*(.*?)\s*\)\s*(?:to\s*\(\s*(.*?)\s*\)\s*)?\z/m)
          return [nil, nil] unless match

          [presence(match[1]), presence(match[2])]
        end

        def presence(string)
          string.nil? || string.empty? ? nil : string
        end

        # @import prelude: `url(x)` / `"x"` / `'x'`, optionally followed by a
        # media query. Returns nil (the rule is dropped) when no URL is found.
        def parse_import(prelude)
          prelude = prelude.to_s.strip
          if (match = prelude.match(/\Aurl\(\s*(.*?)\s*\)/i))
            url = match[1]
          elsif (match = prelude.match(/\A(?:"([^"]*)"|'([^']*)')/))
            url = match[1] || match[2]
          else
            return nil
          end

          url = url.to_s.gsub(/\A["']|["']\z/, "").strip
          return nil if url.empty?

          ImportRule.new(url, prelude[match.end(0)..].to_s.strip)
        end

        def build_style_rule(selectors, declarations)
          return nil if selectors.empty?

          StyleRule.new(selectors, declarations.map { |d| Declaration.new(d[:name], declaration_value(d[:value]), d[:important]) })
        end

        # A declaration's value as the backend hands it over can still hold a
        # comment (inside a function, or in a custom property's raw value) and
        # the whitespace around one. A comment is no token and a declaration's
        # value is trimmed (css-syntax-3 §5.4.6), so `--x: 1px /* c */` is `1px`
        # and `var(--y, /* ) */ 7px)` falls back to `7px`.
        def declaration_value(value)
          CssSource.new(value).without_comments.to_s.strip
        end

        def normalize_selectors(selectors, namespaces = {})
          selectors.map do |selector|
            ast = Internal::SelectorParser.parse!(selector[:text], namespaces: namespaces)
            Selector.new(selector[:text], ast, ast.specificity.to_a)
          end
        rescue DOMException::SyntaxError
          []
        end

        # Parse a bare declaration block (no selector / braces) into an ordered
        # { property => Declaration } hash. The CSSOM's view of both declaration
        # blocks it exposes — a rule's `style` and an element's `style`
        # attribute — so the two cannot drift apart.
        #
        # Cascade order WITHIN one block: an important declaration beats a
        # normal one for the same property whatever their order, and only
        # between declarations of equal importance does the later win. So a
        # normal declaration never displaces an important one already recorded.
        #
        # The block is split at top-level semicolons only: one inside a string,
        # a function (`url(data:a;b)`), a {} block or a comment does not end a
        # declaration (css-syntax-3 §5.4.5).
        def parse_block(text)
          CssSource.new(CssSyntax.preprocess(text.to_s)).split_top_level(";").each_with_object({}) do |chunk, out|
            decl = parse_declaration(chunk)
            next if decl.nil?
            next if !decl.important && out[decl.name]&.important

            out[decl.name] = decl
          end
        end

        # One `property: value` (with an optional `!important`), or nil when the
        # chunk is not a usable declaration.
        def parse_declaration(chunk)
          # Comments are no tokens: drop them before reading the name, the
          # colon and the value, so `/* x: y */` hides nothing after it.
          name, value = CssSource.new(chunk).without_comments.partition_top_level(":")
          return nil unless name

          name = property_name(name.strip)
          value = value.strip
          # Split the `!important` flag off the value before validating it, so
          # the flag round-trips through cssText without leaking into the value.
          important = false
          if (stripped = value[/\A(.*?)!\s*important\s*\z/im, 1])
            important = true
            value = stripped.strip
          end
          return nil if name.empty? || !valid_declaration_value?(name, value)

          Declaration.new(name, value, important)
        end

        # CSSOM property-name normalization, for a name read from a declaration
        # block or handed to `getPropertyValue` / `setProperty` alike: ASCII
        # case-insensitive, except a CUSTOM property, whose name is
        # case-SENSITIVE (`--Foo` and `--foo` are two properties).
        def property_name(name)
          str = name.to_s
          custom_property?(str) ? str : str.downcase
        end

        def custom_property?(name) = name.start_with?("--")

        # Whether `value` is usable for the property `name`; a declaration
        # whose value is not is dropped, not stored. It has to be a
        # <declaration-value> — no top-level `;` or `!`, no closing bracket
        # that closes nothing — so a value cannot end its declaration and
        # start another (`setProperty("--x", "1; color: red")`), and every
        # var() in it has to parse. A custom property's value is otherwise
        # any run of tokens (css-variables-1 §2) — empty (`--x:;`,
        # `--x: /* c */`), or with a colon in it (`--time: 10:30`). Any other
        # property's value has to be non-empty, with no bare colon outside
        # brackets, strings and comments (the second one in "color:: invalid").
        def valid_declaration_value?(name, value)
          source = CssSource.new(value)
          return false unless source.declaration_value?

          unless custom_property?(name)
            return false if value.empty?
            return false if source.partition_top_level(":")
          end

          valid_var_functions?(value)
        end

        # Every var() outside a string or a comment parses: a `var(` in
        # `content: "var(--"` is text.
        def valid_var_functions?(value)
          source = CssSource.new(value)
          index = 0
          while (call = source.next_function("var", index))
            start, close = call
            open = start + 3
            return false if close.nil?
            return false unless valid_var_name_argument?(source.slice(open + 1, close))

            # Continue inside the call, so a nested var() in the fallback is
            # checked by the same rule.
            index = open + 1
          end
          true
        end

        # `var()` takes a name and then, optionally, a comma and a fallback. The
        # name is a free-form production, not yet a custom property name: it is
        # whatever stands before the first top-level comma, and it only has to be
        # non-empty. `var(--x ())` is therefore a syntax error no longer — it
        # parses, is kept, and goes invalid at computed-value time once the name
        # turns out not to name a property.
        #
        # The one shape rule is the {}-wrapping of css-values-5: a free-form
        # production either is a single {} block with something in it, or
        # contains no {} block at all. So `var({--x})` and `var(--x ())` pass
        # while `var({--x} --y)`, `var(--x {--y})` and `var({})` do not.
        def valid_var_name_argument?(inner)
          name, = CustomProperties.split_args(inner)
          return false if name.empty?
          return !name.match?(/[{}]/) unless name.start_with?("{")

          source = CssSource.new(name)
          close = source.matching_bracket(0)
          close == source.length - 1 && !source.slice(1, close).strip.empty?
        end
      end
    end
  end
end
