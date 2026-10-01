# frozen_string_literal: true

require "set"

require_relative "selector_ast"

module Dommy
  module Internal
    # A CSS Selectors (Level 4) *validator*: parses a selector string against the
    # grammar and raises on anything syntactically invalid, so
    # querySelector/querySelectorAll/matches/closest throw a SyntaxError for
    # exactly the inputs the spec requires — cases Nokogiri's CSS parser silently
    # accepts (`[*=test]`, `div % p`, `..x`) or rejects with the wrong error.
    #
    # `parse!` returns the AST that `SelectorMatcher` matches against (it both
    # validates and is the matcher's front end). It is a
    # hand-written tokenizer + recursive-descent parser covering the productions
    # the Selectors spec (and the WPT corpus) exercise: selector lists,
    # combinators, type/universal selectors with namespace prefixes, id/class,
    # attribute selectors (with matchers and case flags), and pseudo-classes /
    # pseudo-elements (functional and simple). Because querySelector has no
    # namespace declarations, any *named* namespace prefix is "undeclared" → a
    # SyntaxError (only `*|`, `|`, and the default empty prefix are allowed).
    module SelectorParser
      class InvalidSelector < StandardError; end

      # Pseudo-elements (used with `::`, plus the four legacy `:` forms). A `::x`
      # outside this set is an unknown pseudo-element → SyntaxError.
      KNOWN_PSEUDO_ELEMENTS = %w[
        before after first-line first-letter selection placeholder marker backdrop
        slotted cue file-selector-button first-letter grammar-error spelling-error
        target-text highlight part view-transition view-transition-group
        view-transition-image-pair view-transition-old view-transition-new
      ].to_set.freeze

      # Functional pseudo-classes (followed by `(...)`). `slotted`/`cue`/`part`
      # are functional pseudo-elements handled in the `::` path.
      SELECTOR_LIST_FUNCTIONS = %w[not is where has matches].to_set.freeze
      NTH_FUNCTIONS = %w[nth-child nth-last-child nth-of-type nth-last-of-type nth-col nth-last-col].to_set.freeze
      IDENT_FUNCTIONS = %w[lang dir].to_set.freeze
      NESTED_SELECTOR_FUNCTIONS = %w[host host-context current].to_set.freeze

      # A parsed AST is a pure function of (selector string, namespaces) and never
      # goes stale as the DOM mutates (unlike the query-result caches, which tag
      # entries with style_generation). So memoize globally: `matches?` / `closest`
      # re-parse on every call, and query* re-parse on every cache miss (i.e. after
      # any mutation), so the same handful of selectors are otherwise re-parsed
      # constantly. Bounded via the same "clear at cap" idiom as the query caches.
      # Lock-free plain Hash: `parse!` is pure Ruby (never releases the GVL), so a
      # read/write is atomic under the GVL — a benign duplicate parse is the worst
      # a race can cause, matching the existing per-document caches.
      AST_CACHE_CAP = 2048

      module_function

      # `namespaces` maps a prefix String to its URI (with the symbol key
      # :default for the default namespace), letting `svg|rect` resolve in a
      # stylesheet that declared `@namespace`. nil/empty (the DOM querySelector
      # path) keeps any named prefix undeclared — a SyntaxError, as before.
      def parse!(selector, namespaces: nil)
        key = [selector.to_s, namespaces]
        cache = (@ast_cache ||= {})
        if cache.key?(key)
          cached = cache[key]
          # An invalid selector is memoized as its SyntaxError so a repeat still
          # throws (the message embeds the selector, so re-raising is exact).
          raise cached if cached.is_a?(::Dommy::DOMException::SyntaxError)

          return cached
        end

        ast =
          begin
            new_parser(selector.to_s, namespaces).parse_selector_list!
          rescue InvalidSelector => e
            error = ::Dommy::DOMException::SyntaxError.new("'#{selector}' is not a valid selector: #{e.message}")
            ast_cache_store(cache, key, error)
            raise error
          end
        ast_cache_store(cache, key, ast)
        ast
      end

      def ast_cache_store(cache, key, value)
        cache.clear if cache.size >= AST_CACHE_CAP
        cache[key] = value
      end

      # Validate `selector`; raise DOMException::SyntaxError if it is not a valid
      # selector list, else return the original string.
      def validate!(selector)
        parse!(selector)
        selector
      end

      # True when `selector` parses cleanly (no raise).
      def valid?(selector)
        validate!(selector)
        true
      rescue ::Dommy::DOMException::SyntaxError
        false
      end

      def new_parser(string, namespaces = nil)
        Parser.new(string, namespaces: namespaces)
      end

      # Recursive-descent parser over a character buffer. Methods raise
      # InvalidSelector on the first grammar violation.
      class Parser
        WS = " \t\r\n\f"

        def initialize(string, in_has: false, namespaces: nil)
          @s = preprocess(string)
          @i = 0
          @n = @s.length
          # True while parsing the argument of a `:has()` — a structurally
          # nested `:has()` is invalid (string occurrences inside quoted
          # attribute values are fine).
          @in_has = in_has
          # prefix String => URI (and :default => default-namespace URI) from a
          # stylesheet's @namespace rules; {} on the DOM querySelector path.
          @namespaces = namespaces || {}
          @default_namespace = @namespaces[:default]
        end

        # selector-list := <complex-selector> (',' <complex-selector>)* with
        # optional surrounding whitespace; an empty list or an empty element
        # (leading/trailing/double comma) is invalid.
        def parse_selector_list!
          skip_ws
          fail!("empty selector") if eof?
          selectors = []
          selectors << parse_complex_selector!
          while peek == ","
            advance
            skip_ws
            fail!("empty selector in list") if eof? || peek == ","
            selectors << parse_complex_selector!
          end
          skip_ws
          fail!("unexpected #{peek.inspect}") unless eof?
          SelectorAST::SelectorList.new(selectors)
        end

        # complex := <compound> ( <combinator> <compound> )*
        # combinator is one of > + ~ >> || or descendant (whitespace). Returns
        # whether the SUBJECT (last) compound is a pseudo-element.
        def parse_complex_selector!
          parts = [SelectorAST::Part.new(nil, parse_compound_selector!)]
          loop do
            had_ws = skip_ws
            # `)` ends a complex selector nested in a functional pseudo
            # (`:not(div)`); `,` / EOF end one at the top level.
            break if eof? || peek == "," || peek == ")"

            if combinator_char?(peek)
              combinator = consume_combinator!
              skip_ws
              fail!("dangling combinator") if eof? || peek == "," || combinator_char?(peek)
              parts << SelectorAST::Part.new(combinator, parse_compound_selector!)
            elsif had_ws
              # Descendant combinator (whitespace) — next must be a compound.
              parts << SelectorAST::Part.new(:descendant, parse_compound_selector!)
            else
              fail!("unexpected #{peek.inspect}")
            end
          end
          SelectorAST::ComplexSelector.new(parts)
        end

        # One explicit combinator token: > , + , ~ , >> , || .
        def consume_combinator!
          c = peek
          case c
          when ">"
            advance
            if peek == ">" # legacy descendant `>>`
              advance
              :descendant
            else
              :child
            end
          when "+", "~"
            advance
            fail!("invalid combinator") if peek == c # `++`, `~~`
            c == "+" ? :next_sibling : :subsequent_sibling
          when "|"
            fail!("invalid combinator") unless peek(1) == "|"
            advance
            advance
            :column
          else
            fail!("invalid combinator #{c.inspect}")
          end
        end

        def combinator_char?(c)
          c == ">" || c == "+" || c == "~" || (c == "|" && peek(1) == "|")
        end

        # compound := [ <type> | <universal> ]? <subclass>* with at least one
        # simple selector. A type/universal, if present, comes first. Returns
        # whether the compound includes a pseudo-element (always the last token).
        def parse_compound_selector!
          saw_any = false
          type = nil
          subclasses = []
          pseudo_element = nil
          # Optional leading type/universal (may carry a namespace prefix).
          if type_start?
            type = parse_type_or_universal!
            saw_any = true
          end
          loop do
            skip_comments
            c = peek
            break unless c == "#" || c == "." || c == "[" || c == ":"

            # A pseudo-element ends the compound: `::before.foo`,
            # `::before:hover`, `::before::after` are all invalid.
            fail!("selector after pseudo-element") if pseudo_element

            case c
            when "#"
              subclasses << parse_id!
            when "."
              subclasses << parse_class!
            when "["
              subclasses << parse_attribute!
            when ":"
              parsed = parse_pseudo!
              if parsed.is_a?(SelectorAST::PseudoElement)
                pseudo_element = parsed
              else
                subclasses << parsed
              end
            end
            saw_any = true
          end
          fail!("empty compound selector") unless saw_any

          SelectorAST::CompoundSelector.new(type, subclasses, pseudo_element)
        end

        # A compound may start with a type/universal selector when the next token
        # is an ident, `*`, or a namespace prefix (`*|`, `|`, `ident|`).
        def type_start?
          c = peek
          return true if c == "*"
          return true if c == "|"
          return true if ident_start?

          false
        end

        # type := [<ns-prefix>]? (<ident> | '*')
        def parse_type_or_universal!
          # No prefix: the default namespace (if declared) applies to type and
          # universal selectors (but not attribute selectors).
          ns = namespace_prefix_ahead? ? parse_namespace_prefix! : @default_namespace
          if peek == "*"
            advance
            SelectorAST::UniversalSelector.new(ns)
          elsif ident_start?
            SelectorAST::TypeSelector.new(ns, consume_ident!)
          else
            fail!("expected type selector")
          end
        end

        # Is there a namespace prefix (`*|`, `|`, `ident|`) at the cursor, as
        # distinct from a `||` column combinator?
        def namespace_prefix_ahead?
          if peek == "*"
            return peek(1) == "|" && peek(2) != "|"
          end
          if peek == "|"
            return peek(1) != "|"
          end
          if ident_start?
            # Scan the ident, then check for a single '|' (not '||').
            j = scan_ident_end(@i)
            return @s[j] == "|" && @s[j + 1] != "|"
          end
          false
        end

        # ns-prefix := (<ident> | '*')? '|'  — any *named* prefix is undeclared.
        def parse_namespace_prefix!
          ns = nil
          if peek == "*"
            advance
            ns = :any
          elsif peek == "|"
            # empty (no-namespace) prefix
            ns = :none
          elsif ident_start?
            prefix = consume_ident!
            ns = @namespaces[prefix]
            fail_undeclared_namespace! unless ns
          else
            fail!("invalid namespace prefix")
          end
          fail!("expected '|' in namespace prefix") unless peek == "|"
          advance
          ns
        end

        def fail_undeclared_namespace!
          raise InvalidSelector, "undeclared namespace"
        end

        # id := '#' <name>, but Selectors §5.1 adds "the <hash-token>'s value must
        # be an identifier" — so `#1`, whose hash-token is the "unrestricted"
        # kind, is not an id selector at all (`#\31` is the way to write it).
        def parse_id!
          advance # consume '#'
          fail!("invalid id") unless ident_start?
          SelectorAST::IdSelector.new(consume_name!)
        end

        # class := '.' <ident>
        def parse_class!
          advance # consume '.'
          fail!("invalid class") unless ident_start?
          SelectorAST::ClassSelector.new(consume_ident!)
        end

        # attribute := '[' WS? [<ns-prefix>]? <ident> WS?
        #              ( <matcher> WS? (<ident> | <string>) WS? <flag>? WS? )? ']'
        def parse_attribute!
          advance # consume '['
          skip_ws
          ns = attribute_namespace_prefix_ahead? ? parse_namespace_prefix! : nil
          fail!("invalid attribute name") unless ident_start?
          name = consume_ident!
          skip_ws
          matcher = nil
          value = nil
          flag = nil
          # CSS Syntax §5.4.7 closes an open block when the input ends, so
          # `a[href` is read as `a[href]` rather than looking for a matcher that
          # is not there.
          unless eof? || peek == "]"
            matcher = consume_attr_matcher!
            skip_ws
            value = consume_attr_value!
            skip_ws
            flag = consume_attr_flag! if ident_start?
            skip_ws
          end
          # Per CSS tokenizing, EOF implicitly closes an open `[` — so a trailing
          # unclosed attribute selector (`[align="center"`) is still valid.
          return SelectorAST::AttributeSelector.new(ns, name, matcher, value, flag) if eof?

          fail!("unclosed attribute selector") unless peek == "]"
          advance
          SelectorAST::AttributeSelector.new(ns, name, matcher, value, flag)
        end

        # Inside `[...]`, a namespace prefix precedes the attribute name. `*|` is
        # any-namespace; a bare `|`; a named prefix is undeclared.
        def attribute_namespace_prefix_ahead?
          if peek == "*"
            return peek(1) == "|"
          end
          if peek == "|"
            return true
          end
          if ident_start?
            j = scan_ident_end(@i)
            return @s[j] == "|" && @s[j + 1] != "="
          end
          false
        end

        def consume_attr_matcher!
          c = peek
          if "~|^$*".include?(c)
            advance
            fail!("invalid attribute matcher") unless peek == "="
            advance
            "#{c}="
          elsif c == "="
            advance
            "="
          else
            fail!("invalid attribute selector")
          end
        end

        def consume_attr_value!
          if peek == '"' || peek == "'"
            consume_string!
          elsif ident_start?
            consume_ident!
          else
            fail!("invalid attribute value")
          end
        end

        # The trailing case-sensitivity flag: a single i/I/s/S, then only WS or ].
        def consume_attr_flag!
          flag = peek
          fail!("invalid attribute flag") unless %w[i I s S].include?(flag)
          advance
          fail!("invalid attribute flag") unless eof? || WS.include?(peek) || peek == "]"
          flag.downcase
        end

        # The four pseudo-elements that also accept the legacy one-colon syntax;
        # written with `:` they are still pseudo-elements (match no element).
        LEGACY_PSEUDO_ELEMENTS = %w[before after first-line first-letter].to_set.freeze

        # pseudo := '::' <pseudo-element> | ':' (<pseudo-class> | <function>).
        # Returns true when this is a pseudo-element (so a compound ending here
        # matches no element).
        def parse_pseudo!
          advance # first ':'
          if peek == ":"
            advance # pseudo-element '::'
            parse_pseudo_element!
          else
            parse_pseudo_class!
          end
        end

        def parse_pseudo_element!
          fail!("invalid pseudo-element") unless ident_start?
          name = consume_ident!.downcase
          argument = nil
          if peek == "("
            argument = consume_function_args!(name, pseudo_element: true)
          else
            fail!("unknown pseudo-element '#{name}'") unless KNOWN_PSEUDO_ELEMENTS.include?(name)
          end
          SelectorAST::PseudoElement.new(name, argument)
        end

        # Returns true when the `:name` is actually a legacy pseudo-element.
        def parse_pseudo_class!
          fail!("invalid pseudo-class") unless ident_start?
          name = consume_ident!.downcase
          if peek == "("
            SelectorAST::PseudoClass.new(name, consume_function_args!(name, pseudo_element: false))
          else
            fail!("unknown pseudo-class '#{name}'") unless KNOWN_PSEUDOS.include?(name)
            if LEGACY_PSEUDO_ELEMENTS.include?(name)
              SelectorAST::PseudoElement.new(name, nil)
            else
              SelectorAST::PseudoClass.new(name, nil)
            end
          end
        end

        # Validate `name(...)` per the function's argument grammar.
        def consume_function_args!(name, pseudo_element:)
          advance # consume '('
          # :is()/:where()/:matches() take a forgiving selector list, which may be
          # empty (matches nothing); other functional pseudos require an argument.
          arg = consume_function_argument_source(allow_empty: %w[is where matches].include?(name))
          arg_parser = Parser.new(arg, in_has: @in_has, namespaces: @namespaces)
          if pseudo_element
            # ::slotted(<compound>), ::part(<ident>+), ::cue(<selector>), …
            case name
            when "slotted" then arg_parser.parse_complex_selector!
            when "part" then arg.split(/\s+/).reject(&:empty?)
            else arg_parser.parse_complex_selector!
            end
          elsif %w[is where matches].include?(name)
            parse_selector_argument_list(arg, forgiving: true)
          elsif name == "not"
            parse_selector_argument_list(arg, forgiving: false)
          elsif name == "has"
            fail!("nested :has() is invalid") if @in_has
            rels = parse_relative_selector_argument_list(arg)
            fail!("pseudo-element in :has() is invalid") if rels.any? { |r| r.complex.pseudo_element? }
            rels
          elsif NTH_FUNCTIONS.include?(name)
            parse_nth_argument(arg, allow_of: %w[nth-child nth-last-child].include?(name))
          elsif IDENT_FUNCTIONS.include?(name)
            parse_ident_argument(arg)
          elsif NESTED_SELECTOR_FUNCTIONS.include?(name)
            parse_selector_argument_list(arg, forgiving: false)
          elsif KNOWN_PSEUDOS.include?(name)
            # A known pseudo used functionally we don't model the args of — accept
            # a balanced, non-empty argument run.
            fail!("empty function arguments") if arg.strip.empty?
            arg.strip
          else
            fail!("unknown functional pseudo-class '#{name}'")
          end
        end

        def consume_function_argument_source(allow_empty: false)
          skip_ws
          start = @i
          depth = 0
          until eof?
            c = peek
            break if c == ")" && depth.zero?

            if (j = Parser.atom_end(@s, @i))
              @i = j
              next
            end

            if c == "(" || c == "["
              depth += 1
            elsif c == ")" || c == "]"
              depth -= 1
            end
            advance
          end
          arg = @s[start...@i].to_s.strip
          fail!("empty function arguments") if arg.empty? && !allow_empty
          advance if peek == ")"
          arg
        end

        def parse_selector_argument_list(source, forgiving:)
          clauses = split_selector_source(source)
          selectors = []
          clauses.each do |clause|
            begin
              selectors.concat(Parser.new(clause, in_has: @in_has, namespaces: @namespaces).parse_selector_list!.selectors)
            rescue InvalidSelector
              raise unless forgiving
            end
          end
          # A forgiving selector list (`:is`/`:where`) whose every clause is
          # invalid is still valid — it just matches nothing (empty list).
          fail!("empty selector list") if selectors.empty? && !forgiving
          SelectorAST::SelectorList.new(selectors)
        end

        def parse_relative_selector_argument_list(source)
          split_selector_source(source).map do |clause|
            Parser.new(clause, in_has: true, namespaces: @namespaces).parse_relative_selector!
          end
        end

        def parse_relative_selector!
          skip_ws
          leading = combinator_char?(peek) ? consume_combinator! : :descendant
          skip_ws
          complex = parse_complex_selector!
          skip_ws
          fail!("unexpected #{peek.inspect}") unless eof?
          SelectorAST::RelativeSelector.new(leading, complex)
        end

        def split_selector_source(source)
          out = []
          current = +""
          depth = 0
          i = 0
          while i < source.length
            if (j = Parser.atom_end(source, i))
              current << source[i...j]
              i = j
              next
            end

            ch = source[i]
            i += 1
            if ch == "(" || ch == "["
              depth += 1
            elsif ch == ")" || ch == "]"
              depth -= 1 if depth.positive?
            elsif ch == "," && depth.zero?
              out << current.strip
              current = +""
              next
            end
            current << ch
          end
          out << current.strip
          out.reject(&:empty?)
        end

        # Index just past the escape, string or comment starting at `j` in
        # `source`, or nil if none starts there. Their contents are not
        # structure: an escaped `,` or `)` belongs to an ident (§4.3.8), a
        # string runs to its closing quote or a newline (§4.3.5), and a comment
        # produces no token at all (§4.3.2). Anything that splits or balances
        # selector source must step over them whole.
        def self.atom_end(source, j)
          c = source[j]
          if c == "\\"
            return nil if source[j + 1] == "\n" # not a valid escape

            [j + 2, source.length].min
          elsif c == '"' || c == "'"
            k = j + 1
            while k < source.length
              d = source[k]
              return k + 1 if d == c
              return k if d == "\n"

              k += d == "\\" ? 2 : 1
            end
            source.length
          elsif c == "/" && source[j + 1] == "*"
            close = source.index("*/", j + 2)
            close ? close + 2 : source.length
          end
        end

        def parse_nth_argument(source, allow_of:)
          a, b, rest = Parser.new(source, in_has: @in_has, namespaces: @namespaces)
                             .parse_an_plus_b!(allow_of: allow_of)
          of_list = rest && parse_selector_argument_list(rest, forgiving: false)
          SelectorAST::NthExpression.new(a, b, of_list)
        end

        # css-syntax-3 §9: An+B is a grammar over tokens, not characters. A
        # comment between two tokens is no token at all (`2n/**/+1` is
        # `2n +1`), escapes are decoded before the value is compared
        # (`2\6E+1` is `2n+1`), and a sign binds to the token that follows it
        # (`- n` is not `-n`). So read the tokens first and match the
        # productions on them. With `allow_of`, stop at an `of` ident and
        # return the source after it as the selector list.
        AnbToken = Struct.new(:type, :value, :integer, :sign, :unit)

        def parse_an_plus_b!(allow_of:)
          tokens, rest = an_plus_b_tokens!(allow_of: allow_of)
          a, b = match_an_plus_b(tokens)
          [a, b, rest]
        end

        def an_plus_b_tokens!(allow_of:)
          tokens = []
          loop do
            skip_comment! while at_comment?
            return [tokens, nil] if eof?

            c = peek
            if WS.include?(c)
              advance while !eof? && WS.include?(peek)
              tokens << AnbToken.new(:ws)
            elsif starts_number?
              tokens << consume_numeric_token!
            elsif ident_start?
              value = consume_ident!
              return [tokens, @s[@i..]] if allow_of && value.downcase(:ascii) == "of"

              tokens << AnbToken.new(:ident, value)
            else
              advance
              tokens << AnbToken.new(:delim, c)
            end
          end
        end

        # A code point (or nil, past the end) that is an ASCII digit.
        def digit?(ch) = !ch.nil? && ch.match?(/[0-9]/)

        # §4.3.10 "check if three code points would start a number".
        def starts_number?
          c = peek
          if c == "+" || c == "-"
            digit?(peek(1)) || (peek(1) == "." && digit?(peek(2)))
          elsif c == "."
            digit?(peek(1))
          else
            digit?(c)
          end
        end

        # §4.3.3 / §4.3.13, keeping only what An+B looks at: the integer value,
        # whether it is an integer, the sign character, and a dimension's unit.
        def consume_numeric_token!
          sign = (peek == "+" || peek == "-") ? peek : nil
          advance if sign
          start = @i
          advance while digit?(peek)
          value = @s[start...@i].to_i
          value = -value if sign == "-"
          integer = true
          if peek == "." && digit?(peek(1))
            integer = false
            advance
            advance while digit?(peek)
          end
          if (peek == "e" || peek == "E") &&
             (digit?(peek(1)) || ((peek(1) == "+" || peek(1) == "-") && digit?(peek(2))))
            integer = false
            advance
            advance unless digit?(peek)
            advance while digit?(peek)
          end
          if ident_start?
            AnbToken.new(:dimension, value, integer, sign, consume_ident!)
          elsif peek == "%"
            advance
            AnbToken.new(:percentage, value, integer, sign)
          else
            AnbToken.new(:number, value, integer, sign)
          end
        end

        # The productions of §9.2, on tokens. Whitespace may separate any two
        # tokens except a `+` and the `n`-ident after it (the † note).
        def match_an_plus_b(tokens)
          t = tokens.drop_while { |x| x.type == :ws }.reverse.drop_while { |x| x.type == :ws }.reverse
          fail!("invalid An+B expression") if t.empty?

          plus = t.first.type == :delim && t.first.value == "+"
          if plus
            t.shift
            fail!("invalid An+B expression") unless t.first&.type == :ident
          end
          first = t.shift
          rest = t.drop_while { |x| x.type == :ws }

          case first.type
          when :ident
            v = first.value.downcase(:ascii)
            if !plus && v == "odd" then done(rest, 2, 1)
            elsif !plus && v == "even" then done(rest, 2, 0)
            elsif v == "n" then with_b(rest, 1)
            elsif !plus && v == "-n" then with_b(rest, -1)
            elsif v == "n-" then with_signless_b(rest, 1)
            elsif !plus && v == "-n-" then with_signless_b(rest, -1)
            elsif (m = v.match(/\An-([0-9]+)\z/)) then done(rest, 1, -m[1].to_i)
            elsif !plus && (m = v.match(/\A-n-([0-9]+)\z/)) then done(rest, -1, -m[1].to_i)
            else fail!("invalid An+B expression")
            end
          when :number
            fail!("invalid An+B expression") unless first.integer

            done(rest, 0, first.value)
          when :dimension
            fail!("invalid An+B expression") unless first.integer

            u = first.unit.downcase(:ascii)
            if u == "n" then with_b(rest, first.value)
            elsif u == "n-" then with_signless_b(rest, first.value)
            elsif (m = u.match(/\An-([0-9]+)\z/)) then done(rest, first.value, -m[1].to_i)
            else fail!("invalid An+B expression")
            end
          else
            fail!("invalid An+B expression")
          end
        end

        def done(rest, a, b)
          fail!("invalid An+B expression") unless rest.empty?

          [a, b]
        end

        # After `An`: nothing, a signed integer, or `+`/`-` and a signless one.
        def with_b(rest, a)
          return [a, 0] if rest.empty?

          head = rest.first
          if head.type == :number && head.integer && head.sign
            done(rest.drop(1), a, head.value)
          elsif head.type == :delim && (head.value == "+" || head.value == "-")
            signless = rest.drop(1).drop_while { |x| x.type == :ws }
            n = signless.first
            fail!("invalid An+B expression") unless n&.type == :number && n.integer && n.sign.nil?

            done(signless.drop(1), a, head.value == "-" ? -n.value : n.value)
          else
            fail!("invalid An+B expression")
          end
        end

        # After `An-`: a signless integer, negated.
        def with_signless_b(rest, a)
          n = rest.first
          fail!("invalid An+B expression") unless n&.type == :number && n.integer && n.sign.nil?

          done(rest.drop(1), a, -n.value)
        end

        def parse_ident_argument(source)
          parts = source.split(/\s*,\s*|\s+/).reject(&:empty?)
          fail!("expected identifier") if parts.empty?
          parts.length == 1 ? parts.first : parts
        end

        # ---- token helpers -------------------------------------------------

        # css-syntax-3 §3.3 "filter code points", the pass that runs before the
        # tokenizer sees anything: the three newline forms become U+000A, and
        # U+0000 becomes U+FFFD. The replacement character is itself an ident
        # code point, so `.a<NUL>b` names the class `a<U+FFFD>b` rather than
        # being a syntax error.
        NEEDS_FILTERING = /[\r\f\u0000]/

        def preprocess(string)
          return string unless string.match?(NEEDS_FILTERING)

          string.gsub(/\r\n|[\r\f]/, "\n").gsub("\u0000", "\uFFFD")
        end

        def consume_string!
          quote = peek
          value = +""
          advance
          until eof?
            c = peek
            if c == "\\"
              # §4.3.5 differs from an ident here: a backslash before the end of
              # the input adds nothing, and one before a newline continues the
              # line (both are consumed and dropped).
              if peek(1).nil?
                advance
                next
              elsif peek(1) == "\n"
                advance
                advance
                next
              end
              start = @i
              consume_escape!
              escaped = @s[start...@i]
              value << decode_css_identifier(escaped)
              next
            elsif c == quote
              advance
              return value
            elsif c == "\n"
              fail!("newline in string")
            end
            value << c
            advance
          end
          # EOF implicitly closes an open string (CSS tokenizing); only a raw
          # newline inside a string is a parse error.
          value
        end

        # Consume an identifier (assumes ident_start?). Returns the text.
        def consume_ident!
          start = @i
          # leading hyphen(s)
          advance if peek == "-"
          if peek == "-"
            # `--foo`: §4.3.11 lets a second U+002D start the ident, so a custom
            # property's name is a class selector like any other.
            advance
          elsif valid_escape?
            consume_escape!
          elsif ident_letter?(peek)
            advance
          else
            fail!("invalid identifier")
          end
          consume_name_rest!
          decode_css_identifier(@s[start...@i])
        end

        # Consume a name (id token body): like an ident but may start with a
        # digit / hyphen sequence.
        def consume_name!
          start = @i
          consume_name_rest!(require_one: true)
          decode_css_identifier(@s[start...@i])
        end

        def consume_name_rest!(require_one: false)
          count = 0
          loop do
            c = peek
            if valid_escape?
              consume_escape!
              count += 1
            elsif name_char?(c)
              advance
              count += 1
            else
              break
            end
          end
          fail!("empty name") if require_one && count.zero?
        end

        def consume_escape!
          advance # backslash
          # §4.3.7: a backslash at EOF is a parse error that yields U+FFFD, not a
          # failure — `.a\` names the class `a<U+FFFD>` (decode_css_identifier
          # turns the dangling backslash into it).
          return if eof?

          if hex_digit?(peek)
            count = 0
            while count < 6 && hex_digit?(peek)
              advance
              count += 1
            end
            advance if !eof? && WS.include?(peek)
          else
            advance # at least one char follows
          end
        end

        def decode_css_identifier(value)
          out = +""
          i = 0
          while i < value.length
            c = value[i]
            unless c == "\\"
              out << c
              i += 1
              next
            end

            i += 1
            # A backslash with nothing after it (the input ended): §4.3.7 again.
            if i >= value.length
              out << "\uFFFD"
              break
            end

            hex = value[i, 6].to_s[/\A[0-9A-Fa-f]{1,6}/]
            if hex
              codepoint = hex.to_i(16)
              out << escaped_code_point(codepoint)
              i += hex.length
              i += 1 if i < value.length && WS.include?(value[i])
            else
              out << value[i]
              i += 1
            end
          end
          out
        end

        # §4.3.7: zero, a surrogate, or anything past U+10FFFF (the maximum
        # allowed code point) is U+FFFD. None of them is a character Ruby can
        # build, so they must not reach Integer#chr.
        def escaped_code_point(codepoint)
          if codepoint.zero? || (0xD800..0xDFFF).cover?(codepoint) || codepoint > 0x10FFFF
            "\uFFFD"
          else
            codepoint.chr(Encoding::UTF_8)
          end
        end

        # ---- character classification --------------------------------------

        def ident_start?
          c = peek
          return false if c.nil?
          return true if ident_letter?(c)
          return true if valid_escape?
          # leading '-' is an ident start if followed by ident-letter / '-' / esc
          if c == "-"
            nxt = peek(1)
            return !nxt.nil? && (ident_letter?(nxt) || nxt == "-" || valid_escape?(1))
          end
          false
        end

        # §4.3.8: a backslash starts a valid escape unless a newline follows it.
        # Every other pair counts, the end of the input included.
        def valid_escape?(offset = 0)
          peek(offset) == "\\" && peek(offset + 1) != "\n"
        end

        # css-syntax-3 §4.2 "non-ASCII ident code point". Not everything from
        # U+0080 up: the spec narrowed it to this list, aligned with HTML's valid
        # custom element name. U+2603 SNOWMAN falls between two of the ranges, so
        # it cannot be written into a selector at all except escaped (`.\2603 `).
        NON_ASCII_IDENT_RANGES = [
          0xB7..0xB7, 0xC0..0xD6, 0xD8..0xF6, 0xF8..0x37D, 0x37F..0x1FFF,
          0x200C..0x200D, 0x203F..0x2040, 0x2070..0x218F, 0x2C00..0x2FEF,
          0x3001..0xD7FF, 0xF900..0xFDCF, 0xFDF0..0xFFFD,
        ].freeze

        def non_ascii_ident?(c)
          codepoint = c.ord
          return false if codepoint < 0x80
          return true if codepoint >= 0x10000

          NON_ASCII_IDENT_RANGES.any? { |range| range.cover?(codepoint) }
        end

        # An ident-start code point: a letter, an underscore, or one of the
        # non-ASCII ident code points.
        def ident_letter?(c)
          return false if c.nil?

          c.match?(/[A-Za-z_]/) || non_ascii_ident?(c)
        end

        # An ident code point: an ident-start one, a digit, or U+002D.
        def name_char?(c)
          return false if c.nil?

          c.match?(/[A-Za-z0-9_\-]/) || non_ascii_ident?(c)
        end

        def hex_digit?(c) = !c.nil? && c.match?(/[0-9A-Fa-f]/)

        # Index just past the identifier starting at `from` (no validation).
        def scan_ident_end(from)
          j = from
          j += 1 if @s[j] == "-"
          while (ch = @s[j])
            if ch == "\\" && @s[j + 1] != "\n"
              j += 1
              if @s[j]&.match?(/[0-9A-Fa-f]/)
                count = 0
                while count < 6 && @s[j]&.match?(/[0-9A-Fa-f]/)
                  j += 1
                  count += 1
                end
                j += 1 if @s[j] && WS.include?(@s[j])
              else
                j += 1 if @s[j]
              end
            elsif name_char?(ch)
              j += 1
            else
              break
            end
          end
          j
        end

        # ---- cursor --------------------------------------------------------

        def peek(offset = 0) = @s[@i + offset]

        def peek_word
          j = @i
          j += 1 while j < @n && @s[j].match?(/[A-Za-z]/)
          @s[@i...j]
        end

        def advance = @i += 1

        # Whitespace, and the comments that may be interleaved with it. Reports
        # whether any *whitespace* was passed — a comment is not whitespace, so
        # the caller that turns "there was space here" into a descendant
        # combinator must not be told one was there.
        def skip_ws
          moved = false
          loop do
            if !eof? && WS.include?(peek)
              advance
              moved = true
            elsif at_comment?
              skip_comment!
            else
              return moved
            end
          end
        end

        # §4.3.2: the tokenizer consumes `/* … */` and emits nothing for it, so a
        # comment can sit between any two tokens of a selector — including
        # between the simple selectors of one compound (`.a/* c */.b`).
        def skip_comments
          skip_comment! while at_comment?
        end

        def at_comment? = peek == "/" && peek(1) == "*"

        def skip_comment!
          advance # '/'
          advance # '*'
          advance until eof? || (peek == "*" && peek(1) == "/")
          # An unterminated comment ends at EOF: a parse error, not a failure.
          return if eof?

          advance # '*'
          advance # '/'
        end

        def eof?(offset = 0) = (@i + offset) >= @n

        def fail!(message)
          raise InvalidSelector, message
        end
      end
    end
  end
end
