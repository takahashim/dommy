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
    # This only VALIDATES; matching is still delegated to the backend. It is a
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

      module_function

      def parse!(selector)
        new_parser(selector.to_s).parse_selector_list!
      rescue InvalidSelector => e
        raise ::Dommy::DOMException::SyntaxError, "'#{selector}' is not a valid selector: #{e.message}"
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

      # Return `selector` with the comma-clauses whose subject is a pseudo-element
      # removed (`::before`, `:first-line` — they match no element, so dropping
      # them is what querySelector should do; the backend would otherwise error or
      # mis-parse `::`). If EVERY clause is a pseudo-element, returns a selector
      # that matches nothing. Assumes `selector` is already known valid. Plain
      # selectors (no `:`) are returned untouched without re-parsing.
      def matchable_selector(selector)
        s = selector.to_s
        return s unless s.include?(":")

        parser = Parser.new(s)
        parser.parse_selector_list!
        clauses = parser.clauses
        return s unless clauses.any? { |c| c[:pseudo_subject] }

        kept = clauses.reject { |c| c[:pseudo_subject] }
        kept.empty? ? ":not(*)" : kept.map { |c| c[:text] }.join(", ")
      rescue InvalidSelector
        s
      end

      def new_parser(string)
        Parser.new(string)
      end

      # Recursive-descent parser over a character buffer. Methods raise
      # InvalidSelector on the first grammar violation.
      class Parser
        WS = " \t\r\n\f"

        # Per top-level clause: { text:, pseudo_subject: } where pseudo_subject is
        # true when the clause's subject (rightmost compound) is a pseudo-element
        # (`::before`, `:first-line`) — such a clause matches no element.
        attr_reader :clauses

        def initialize(string, in_has: false)
          @s = string
          @i = 0
          @n = string.length
          @clauses = []
          # True while parsing the argument of a `:has()` — a structurally
          # nested `:has()` is invalid (string occurrences inside quoted
          # attribute values are fine).
          @in_has = in_has
        end

        # selector-list := <complex-selector> (',' <complex-selector>)* with
        # optional surrounding whitespace; an empty list or an empty element
        # (leading/trailing/double comma) is invalid.
        def parse_selector_list!
          skip_ws
          fail!("empty selector") if eof?
          selectors = []
          selectors << record_clause { parse_complex_selector! }
          while peek == ","
            advance
            skip_ws
            fail!("empty selector in list") if eof? || peek == ","
            selectors << record_clause { parse_complex_selector! }
          end
          skip_ws
          fail!("unexpected #{peek.inspect}") unless eof?
          SelectorAST::SelectorList.new(selectors)
        end

        # Capture a clause's source text + whether its subject is a pseudo-element.
        def record_clause
          start = @i
          complex = yield
          @clauses << {text: @s[start...@i].strip, pseudo_subject: complex.pseudo_element?}
          complex
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
          ns = namespace_prefix_ahead? ? parse_namespace_prefix! : nil
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
            ns = consume_ident!
            fail_undeclared_namespace!
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

        # id := '#' <name>  (a hash token; `#` alone or `#` + non-name invalid)
        def parse_id!
          advance # consume '#'
          fail!("invalid id") unless name_char_start?(allow_leading_digit: true)
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
          unless peek == "]"
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
          arg = consume_function_argument_source
          arg_parser = Parser.new(arg, in_has: @in_has)
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

        def consume_function_argument_source
          skip_ws
          start = @i
          depth = 0
          until eof?
            c = peek
            break if c == ")" && depth.zero?

            if c == "(" || c == "["
              depth += 1
            elsif c == ")" || c == "]"
              depth -= 1
            elsif c == '"' || c == "'"
              consume_string!
              next
            end
            advance
          end
          arg = @s[start...@i].to_s.strip
          fail!("empty function arguments") if arg.empty?
          advance if peek == ")"
          arg
        end

        def parse_selector_argument_list(source, forgiving:)
          clauses = split_selector_source(source)
          selectors = []
          clauses.each do |clause|
            begin
              selectors.concat(Parser.new(clause, in_has: @in_has).parse_selector_list!.selectors)
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
            Parser.new(clause, in_has: true).parse_relative_selector!
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
          quote = nil
          source.each_char do |ch|
            if quote
              quote = nil if ch == quote
            elsif ch == '"' || ch == "'"
              quote = ch
            elsif ch == "(" || ch == "["
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

        def parse_nth_argument(source, allow_of:)
          expr = source.strip
          of_list = nil
          if allow_of && (match = expr.match(/\s+of\s+/i))
            anb = expr[0...match.begin(0)].strip
            selectors = expr[match.end(0)..].strip
            of_list = parse_selector_argument_list(selectors, forgiving: false)
          else
            anb = expr
          end
          a, b = parse_an_plus_b(anb)
          SelectorAST::NthExpression.new(a, b, of_list)
        end

        # css-syntax An+B: `<integer>` and `n` form a single token (`3n`), so
        # whitespace between them (`3 n`) is invalid; whitespace around the
        # operator before the B part (`3n + 1`) is fine.
        AN_PLUS_B = /\A([+-])?[ \t\r\n\f]*(\d+)?n(?:[ \t\r\n\f]*([+-])[ \t\r\n\f]*(\d+))?\z/

        def parse_an_plus_b(source)
          s = source.strip.downcase
          return [2, 1] if s == "odd"
          return [2, 0] if s == "even"
          return [0, Integer(s.delete(" \t\r\n\f"))] if s.match?(/\A[+-]?[ \t\r\n\f]*\d+\z/)
          if (m = s.match(AN_PLUS_B))
            a = (m[2] ? m[2].to_i : 1)
            a = -a if m[1] == "-"
            b = m[3] ? Integer("#{m[3]}#{m[4]}") : 0
            return [a, b]
          end
          fail!("invalid An+B expression")
        end

        def parse_ident_argument(source)
          parts = source.split(/\s*,\s*|\s+/).reject(&:empty?)
          fail!("expected identifier") if parts.empty?
          parts.length == 1 ? parts.first : parts
        end

        # ---- token helpers -------------------------------------------------

        def consume_string!
          quote = peek
          value = +""
          advance
          until eof?
            c = peek
            if c == "\\"
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
          if peek == "\\"
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
            if c == "\\"
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
          fail!("trailing backslash") if eof?
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
            break if i >= value.length

            hex = value[i, 6].to_s[/\A[0-9A-Fa-f]{1,6}/]
            if hex
              codepoint = hex.to_i(16)
              out << (codepoint.zero? ? "\uFFFD" : codepoint.chr(Encoding::UTF_8))
              i += hex.length
              i += 1 if i < value.length && WS.include?(value[i])
            else
              out << value[i]
              i += 1
            end
          end
          out
        end

        # ---- character classification --------------------------------------

        def ident_start?
          c = peek
          return false if c.nil?
          return true if ident_letter?(c)
          return true if c == "\\" && !eof?(1)
          # leading '-' is an ident start if followed by ident-letter / '-' / esc
          if c == "-"
            nxt = peek(1)
            return !nxt.nil? && (ident_letter?(nxt) || nxt == "-" || nxt == "\\")
          end
          false
        end

        # A letter, underscore, or non-ASCII (>= U+0080) start char.
        def ident_letter?(c)
          return false if c.nil?

          c.match?(/[A-Za-z_]/) || c.ord >= 0x80
        end

        def name_char?(c)
          return false if c.nil?

          c.match?(/[A-Za-z0-9_\-]/) || c.ord >= 0x80
        end

        def name_char_start?(allow_leading_digit: false)
          c = peek
          return false if c.nil?
          return true if c == "\\" && !eof?(1)
          return true if name_char?(c) && (allow_leading_digit || !digit?(c))

          false
        end

        def digit?(c) = !c.nil? && c >= "0" && c <= "9"

        def hex_digit?(c) = !c.nil? && c.match?(/[0-9A-Fa-f]/)

        # Index just past the identifier starting at `from` (no validation).
        def scan_ident_end(from)
          j = from
          j += 1 if @s[j] == "-"
          while (ch = @s[j])
            if ch == "\\"
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
            elsif ch.match?(/[A-Za-z0-9_\-]/) || ch.ord >= 0x80
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

        def skip_ws
          moved = false
          while !eof? && WS.include?(peek)
            advance
            moved = true
          end
          moved
        end

        def eof?(offset = 0) = (@i + offset) >= @n

        def fail!(message)
          raise InvalidSelector, message
        end
      end
    end
  end
end
