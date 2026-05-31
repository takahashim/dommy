# frozen_string_literal: true

require "set"

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

      # Validate `selector`; raise DOMException::SyntaxError if it is not a valid
      # selector list, else return the original string.
      def validate!(selector)
        new_parser(selector.to_s).parse_selector_list!
        selector
      rescue InvalidSelector => e
        raise ::Dommy::DOMException::SyntaxError, "'#{selector}' is not a valid selector: #{e.message}"
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

        def initialize(string)
          @s = string
          @i = 0
          @n = string.length
          @clauses = []
        end

        # selector-list := <complex-selector> (',' <complex-selector>)* with
        # optional surrounding whitespace; an empty list or an empty element
        # (leading/trailing/double comma) is invalid.
        def parse_selector_list!
          skip_ws
          fail!("empty selector") if eof?
          record_clause { parse_complex_selector! }
          while peek == ","
            advance
            skip_ws
            fail!("empty selector in list") if eof? || peek == ","
            record_clause { parse_complex_selector! }
          end
          skip_ws
          fail!("unexpected #{peek.inspect}") unless eof?
        end

        # Capture a clause's source text + whether its subject is a pseudo-element.
        def record_clause
          start = @i
          pseudo_subject = yield
          @clauses << {text: @s[start...@i].strip, pseudo_subject: pseudo_subject}
        end

        # complex := <compound> ( <combinator> <compound> )*
        # combinator is one of > + ~ >> || or descendant (whitespace). Returns
        # whether the SUBJECT (last) compound is a pseudo-element.
        def parse_complex_selector!
          pseudo_subject = parse_compound_selector!
          loop do
            had_ws = skip_ws
            # `)` ends a complex selector nested in a functional pseudo
            # (`:not(div)`); `,` / EOF end one at the top level.
            break if eof? || peek == "," || peek == ")"

            if combinator_char?(peek)
              consume_combinator!
              skip_ws
              fail!("dangling combinator") if eof? || peek == "," || combinator_char?(peek)
              pseudo_subject = parse_compound_selector!
            elsif had_ws
              # Descendant combinator (whitespace) — next must be a compound.
              pseudo_subject = parse_compound_selector!
            else
              fail!("unexpected #{peek.inspect}")
            end
          end
          pseudo_subject
        end

        # One explicit combinator token: > , + , ~ , >> , || .
        def consume_combinator!
          c = peek
          case c
          when ">"
            advance
            advance if peek == ">" # legacy descendant `>>`
          when "+", "~"
            advance
            fail!("invalid combinator") if peek == c # `++`, `~~`
          when "|"
            fail!("invalid combinator") unless peek(1) == "|"
            advance
            advance
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
          pseudo_element = false
          # Optional leading type/universal (may carry a namespace prefix).
          if type_start?
            parse_type_or_universal!
            saw_any = true
          end
          loop do
            case peek
            when "#"
              parse_id!
            when "."
              parse_class!
            when "["
              parse_attribute!
            when ":"
              pseudo_element = parse_pseudo!
            else
              break
            end
            saw_any = true
          end
          fail!("empty compound selector") unless saw_any

          pseudo_element
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
          parse_namespace_prefix! if namespace_prefix_ahead?
          if peek == "*"
            advance
          elsif ident_start?
            consume_ident!
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
          if peek == "*"
            advance
          elsif peek == "|"
            # empty (no-namespace) prefix
          elsif ident_start?
            consume_ident!
            fail_undeclared_namespace!
          else
            fail!("invalid namespace prefix")
          end
          fail!("expected '|' in namespace prefix") unless peek == "|"
          advance
        end

        def fail_undeclared_namespace!
          raise InvalidSelector, "undeclared namespace"
        end

        # id := '#' <name>  (a hash token; `#` alone or `#` + non-name invalid)
        def parse_id!
          advance # consume '#'
          fail!("invalid id") unless name_char_start?(allow_leading_digit: true)
          consume_name!
        end

        # class := '.' <ident>
        def parse_class!
          advance # consume '.'
          fail!("invalid class") unless ident_start?
          consume_ident!
        end

        # attribute := '[' WS? [<ns-prefix>]? <ident> WS?
        #              ( <matcher> WS? (<ident> | <string>) WS? <flag>? WS? )? ']'
        def parse_attribute!
          advance # consume '['
          skip_ws
          parse_namespace_prefix! if attribute_namespace_prefix_ahead?
          fail!("invalid attribute name") unless ident_start?
          consume_ident!
          skip_ws
          unless peek == "]"
            consume_attr_matcher!
            skip_ws
            consume_attr_value!
            skip_ws
            consume_attr_flag! if ident_start?
            skip_ws
          end
          # Per CSS tokenizing, EOF implicitly closes an open `[` — so a trailing
          # unclosed attribute selector (`[align="center"`) is still valid.
          return if eof?

          fail!("unclosed attribute selector") unless peek == "]"
          advance
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
          elsif c == "="
            advance
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
            true
          else
            parse_pseudo_class!
          end
        end

        def parse_pseudo_element!
          fail!("invalid pseudo-element") unless ident_start?
          name = consume_ident!.downcase
          if peek == "("
            consume_function_args!(name, pseudo_element: true)
          else
            fail!("unknown pseudo-element '#{name}'") unless KNOWN_PSEUDO_ELEMENTS.include?(name)
          end
        end

        # Returns true when the `:name` is actually a legacy pseudo-element.
        def parse_pseudo_class!
          fail!("invalid pseudo-class") unless ident_start?
          name = consume_ident!.downcase
          if peek == "("
            consume_function_args!(name, pseudo_element: false)
            false
          else
            fail!("unknown pseudo-class '#{name}'") unless KNOWN_PSEUDOS.include?(name)
            LEGACY_PSEUDO_ELEMENTS.include?(name)
          end
        end

        # Validate `name(...)` per the function's argument grammar.
        def consume_function_args!(name, pseudo_element:)
          advance # consume '('
          skip_ws
          if pseudo_element
            # ::slotted(<compound>), ::part(<ident>+), ::cue(<selector>), …
            case name
            when "slotted" then parse_complex_selector!
            when "part" then consume_ident_sequence!
            else parse_complex_selector!
            end
          elsif SELECTOR_LIST_FUNCTIONS.include?(name)
            parse_inner_selector_list!
          elsif NTH_FUNCTIONS.include?(name)
            consume_nth!
          elsif IDENT_FUNCTIONS.include?(name)
            consume_ident_sequence!
          elsif NESTED_SELECTOR_FUNCTIONS.include?(name)
            parse_inner_selector_list!
          elsif KNOWN_PSEUDOS.include?(name)
            # A known pseudo used functionally we don't model the args of — accept
            # a balanced, non-empty argument run.
            consume_balanced_until_close!
          else
            fail!("unknown functional pseudo-class '#{name}'")
          end
          skip_ws
          # EOF implicitly closes an open `(` (`::slotted(foo`), like the `[`
          # case above.
          return if eof?

          fail!("unclosed pseudo-class function") unless peek == ")"
          advance
        end

        # A selector list inside :not()/:is()/:where()/:has() — `:has` allows a
        # leading combinator (relative selector), the others do not.
        def parse_inner_selector_list!
          skip_ws
          consume_combinator! if combinator_char?(peek) # tolerate relative selectors
          skip_ws
          parse_complex_selector!
          while peek == ","
            advance
            skip_ws
            consume_combinator! if combinator_char?(peek)
            skip_ws
            parse_complex_selector!
          end
        end

        # An+B microsyntax (`2n`, `-3n+1`, `odd`, `even`, `5`, `n`).
        def consume_nth!
          word = peek_word.downcase
          if word == "odd" || word == "even"
            consume_ident!
            return
          end
          consumed = false
          if peek == "+" || peek == "-"
            advance
            consumed = true
          end
          while digit?(peek)
            advance
            consumed = true
          end
          if peek == "n" || peek == "N"
            advance
            consumed = true
            skip_ws
            if peek == "+" || peek == "-"
              advance
              skip_ws
              fail!("invalid An+B") unless digit?(peek)
              advance while digit?(peek)
            end
          end
          fail!("invalid An+B expression") unless consumed
        end

        def consume_ident_sequence!
          fail!("expected identifier") unless ident_start?
          consume_ident!
          loop do
            skip_ws
            break unless ident_start? || peek == ","

            advance if peek == ","
            skip_ws
            consume_ident! if ident_start?
          end
        end

        # Consume a balanced run up to the matching ')' (for pseudo functions we
        # don't model). Nested ()/[] are balanced; the run must be non-empty.
        def consume_balanced_until_close!
          depth = 0
          started = false
          until eof?
            c = peek
            break if c == ")" && depth.zero?

            started = true
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
          fail!("empty function arguments") unless started
        end

        # ---- token helpers -------------------------------------------------

        def consume_string!
          quote = peek
          advance
          until eof?
            c = peek
            if c == "\\"
              advance
              advance unless eof?
              next
            elsif c == quote
              advance
              return
            elsif c == "\n"
              fail!("newline in string")
            end
            advance
          end
          # EOF implicitly closes an open string (CSS tokenizing); only a raw
          # newline inside a string is a parse error.
          nil
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
          @s[start...@i]
        end

        # Consume a name (id token body): like an ident but may start with a
        # digit / hyphen sequence.
        def consume_name!
          start = @i
          consume_name_rest!(require_one: true)
          @s[start...@i]
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
          advance # at least one char follows
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

        # Index just past the identifier starting at `from` (no validation).
        def scan_ident_end(from)
          j = from
          j += 1 if @s[j] == "-"
          while (ch = @s[j])
            if ch == "\\"
              j += 2
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
