# frozen_string_literal: true

module Dommy
  class URLPattern
    # Translates an ECMAScript regular expression into the Onigmo syntax Ruby's
    # Regexp reads, so URLPattern can match in pure Ruby with the semantics the
    # spec gets from `new RegExp(source, "v")`.
    #
    # The spec compiles every component pattern with the "v" flag (unicodeSets)
    # and "i" for ignoreCase, and the regexp groups a page writes are embedded
    # in that pattern verbatim. This class reads that dialect and does three
    # things with it:
    #
    # 1. Rejects what "v" mode rejects and Onigmo would accept: `\H`, `\m`,
    #    `(?R)`, `a*+`, `[a-]`, a lone `{` or `]`, `(?#…)`, `\A`, `\z`, and so
    #    on. The constructor has to throw a TypeError for these.
    # 2. Rewrites what both accept but read differently: `^` / `$` anchor the
    #    whole input, `.` skips every line terminator, `\s` is Unicode white
    #    space, `\b` is an ASCII word boundary, a named group `(?<x>…)` keeps
    #    the numbered captures around it alive, a backreference to a group
    #    that has not captured matches the empty string, `\p{Script=Greek}`
    #    is spelled `\p{Greek}`, a surrogate pair is one code point and a lone
    #    one matches nothing, `[a--b]` is `[a&&[^b]]`, and `[]` / `[^]` exist.
    # 3. Passes through what both read the same way: `\d` `\w` (ASCII in both),
    #    `\u{…}`, `\cX`, `\xHH`, backreferences, lookaround, `(?:…)`, `(?i:…)`,
    #    nested classes and `&&`.
    #
    # What is left: a variable-length lookbehind `(?<=a+)` and the string
    # properties of "v" mode (`\p{RGI_Emoji}`, `\q{…}`) have no Onigmo form and
    # raise; Onigmo's `i` folds a little wider than ECMAScript's simple case
    # folding; `Script_Extensions=` is read as `Script=`.
    #
    # Spec: https://tc39.es/ecma262/#sec-patterns (with [UnicodeMode, UnicodeSetsMode])
    class RegExpTranslator
      # Raised for a pattern ECMAScript would reject, or one this translator
      # cannot express. A subclass of Bridge::TypeError so a JS host rethrows
      # the `TypeError` the URLPattern constructor owes.
      class Error < Bridge::TypeError; end

      # Compile `source` the way `new RegExp(source, flags)` would, flags being
      # "v" plus "i" when `ignore_case`. Onigmo's own rejections (a lookbehind
      # it cannot bound, a property it does not know) surface as Error too.
      def self.compile(source, ignore_case: false)
        translated = new(source).translate
        Regexp.new(translated, ignore_case ? Regexp::IGNORECASE : 0)
      rescue RegexpError => e
        raise Error, "Invalid regular expression: /#{source}/v: #{e.message}"
      end

      # ECMAScript WhiteSpace + LineTerminator, as a class body. Onigmo's `\s`
      # stops at ASCII and `[[:space:]]` has NEL but not U+FEFF, so neither
      # stands in.
      WHITE_SPACE = "\\t\\n\\u000b\\f\\r\\u0020\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff"
      private_constant :WHITE_SPACE

      # `.` without the "s" flag: anything but a LineTerminator.
      DOT = "[^\\n\\r\\u2028\\u2029]"
      DOT_ALL = "[\\s\\S]"
      private_constant :DOT, :DOT_ALL

      # What a lone surrogate becomes: a UTF-16 code unit no UTF-8 String
      # holds, so nothing matches it. The class form also renders `[]`, and
      # nests where a class needs an empty operand.
      UNMATCHABLE = "(?!)"
      UNMATCHABLE_SET = "[^\\p{Any}]"
      private_constant :UNMATCHABLE, :UNMATCHABLE_SET

      # `\b` and `\B` test IsWordChar on both sides, which is ASCII in
      # ECMAScript. Onigmo's `\b` is Unicode-aware, so spell them out.
      WORD = "[A-Za-z0-9_]"
      WORD_BOUNDARY = "(?:(?<=#{WORD})(?!#{WORD})|(?<!#{WORD})(?=#{WORD}))"
      NON_WORD_BOUNDARY = "(?:(?<=#{WORD})(?=#{WORD})|(?<!#{WORD})(?!#{WORD}))"
      private_constant :WORD, :WORD_BOUNDARY, :NON_WORD_BOUNDARY

      # SyntaxCharacter, the set a `\` may escape anywhere in "v" mode (plus `/`).
      SYNTAX_CHARACTERS = "^$\\.*+?()[]{}|"
      # ClassSetSyntaxCharacter: these have to be escaped inside a class.
      CLASS_SYNTAX_CHARACTERS = "()[]{}/-\\|"
      # ClassSetReservedPunctuator: escapable inside a class, and forbidden
      # there unescaped when doubled (ClassSetReservedDoublePunctuator).
      CLASS_RESERVED_PUNCTUATORS = "&-!#%,:;<=>@`~"
      CLASS_DOUBLE_PUNCTUATORS = "&!#$%*+,.:;<=>?@^`~"
      private_constant :SYNTAX_CHARACTERS, :CLASS_SYNTAX_CHARACTERS,
        :CLASS_RESERVED_PUNCTUATORS, :CLASS_DOUBLE_PUNCTUATORS

      # The lone names `\p{…}` accepts: General_Category values and binary
      # properties, by their long and short aliases (ECMA-262 tables 67-69).
      # A Script name needs `Script=`; `\p{Greek}` is a SyntaxError.
      LONE_PROPERTY_NAMES = %w[
        C Other Cc Control cntrl Cf Format Cn Unassigned Co Private_Use Cs Surrogate
        L Letter LC Cased_Letter Ll Lowercase_Letter Lm Modifier_Letter Lo Other_Letter
        Lt Titlecase_Letter Lu Uppercase_Letter
        M Mark Combining_Mark Mc Spacing_Mark Me Enclosing_Mark Mn Nonspacing_Mark
        N Number Nd Decimal_Number digit Nl Letter_Number No Other_Number
        P Punctuation punct Pc Connector_Punctuation Pd Dash_Punctuation Pe Close_Punctuation
        Pf Final_Punctuation Pi Initial_Punctuation Po Other_Punctuation Ps Open_Punctuation
        S Symbol Sc Currency_Symbol Sk Modifier_Symbol Sm Math_Symbol So Other_Symbol
        Z Separator Zl Line_Separator Zp Paragraph_Separator Zs Space_Separator
        ASCII ASCII_Hex_Digit AHex Alphabetic Alpha Any Assigned Bidi_Control Bidi_C
        Bidi_Mirrored Bidi_M Case_Ignorable CI Cased Changes_When_Casefolded CWCF
        Changes_When_Casemapped CWCM Changes_When_Lowercased CWL Changes_When_NFKC_Casefolded CWKCF
        Changes_When_Titlecased CWT Changes_When_Uppercased CWU Dash Default_Ignorable_Code_Point DI
        Deprecated Dep Diacritic Dia Emoji Emoji_Component EComp Emoji_Modifier EMod
        Emoji_Modifier_Base EBase Emoji_Presentation EPres Extended_Pictographic ExtPict
        Extender Ext Grapheme_Base Gr_Base Grapheme_Extend Gr_Ext Hex_Digit Hex
        IDS_Binary_Operator IDSB IDS_Trinary_Operator IDST ID_Continue IDC ID_Start IDS
        Ideographic Ideo Join_Control Join_C Logical_Order_Exception LOE Lowercase Lower Math
        Noncharacter_Code_Point NChar Pattern_Syntax Pat_Syn Pattern_White_Space Pat_WS
        Quotation_Mark QMark Radical Regional_Indicator RI Sentence_Terminal STerm
        Soft_Dotted SD Terminal_Punctuation Term Unified_Ideograph UIdeo Uppercase Upper
        Variation_Selector VS White_Space space XID_Continue XIDC XID_Start XIDS
      ].to_h { |name| [name, true] }.freeze
      # Properties of strings, "v" mode only. Onigmo has no equivalent.
      STRING_PROPERTY_NAMES = %w[
        Basic_Emoji Emoji_Keycap_Sequence RGI_Emoji_Modifier_Sequence RGI_Emoji_Flag_Sequence
        RGI_Emoji_Tag_Sequence RGI_Emoji_ZWJ_Sequence RGI_Emoji
      ].to_h { |name| [name, true] }.freeze
      # The `name=value` forms; each value is spelled the same way in Onigmo.
      VALUED_PROPERTY_NAMES = %w[General_Category gc Script sc Script_Extensions scx]
        .to_h { |name| [name, true] }.freeze
      private_constant :LONE_PROPERTY_NAMES, :STRING_PROPERTY_NAMES, :VALUED_PROPERTY_NAMES

      # A capturing group on the stack, or one of the other bracket kinds. Only
      # `dot_all` carries state: `(?s:…)` is not emitted, it is applied to each
      # `.` inside.
      Group = Struct.new(:kind, :dot_all)
      private_constant :Group

      # A backreference is emitted after the whole source has been read, once
      # every group it may point at (forward references included) is counted.
      Backref = Struct.new(:name, :number)
      private_constant :Backref

      def initialize(source)
        @source = source.to_s
        @chars = @source.chars
        @pos = 0
        @out = []
        @groups = []
        @group_count = 0
        @group_names = {}
        @quantifiable = false
      end

      def translate
        until eof?
          read_term
        end
        fail_syntax("Unterminated group") unless @groups.empty?
        @out.map { |piece| piece.is_a?(Backref) ? resolve_backref(piece) : piece }.join
      end

      private

      def eof?
        @pos >= @chars.length
      end

      def peek(offset = 0)
        @chars[@pos + offset]
      end

      def advance(count = 1)
        @pos += count
      end

      def emit(text)
        @out << text
      end

      def fail_syntax(message)
        raise Error, "Invalid regular expression: /#{@source}/v: #{message}"
      end

      # ---- outside a class ---------------------------------------------------

      def read_term
        c = peek
        case c
        when "\\"
          advance
          read_atom_escape
        when "."
          advance
          emit(dot_all? ? DOT_ALL : DOT)
          @quantifiable = true
        when "^"
          advance
          emit("\\A")
          @quantifiable = false
        when "$"
          advance
          emit("\\z")
          @quantifiable = false
        when "("
          advance
          read_group_open
        when ")"
          advance
          read_group_close
        when "["
          advance
          emit(read_class)
          @quantifiable = true
        when "|"
          advance
          emit("|")
          @quantifiable = false
        when "*", "+", "?"
          advance
          read_quantifier(c)
        when "{"
          read_brace_quantifier
        when "}", "]"
          fail_syntax("Lone quantifier brackets")
        else
          advance
          emit(literal(c.ord))
          @quantifiable = true
        end
      end

      def read_group_open
        @quantifiable = false
        unless peek == "?"
          open_capture
          return
        end
        advance
        case peek
        when ":"
          advance
          emit("(?:")
          @groups << Group.new(:noncapture, dot_all?)
        when "=", "!"
          emit("(?#{peek}")
          advance
          @groups << Group.new(:lookaround, dot_all?)
        when "<"
          advance
          if peek == "=" || peek == "!"
            emit("(?<#{peek}")
            advance
            @groups << Group.new(:lookaround, dot_all?)
          else
            name = read_group_name
            fail_syntax("Duplicate capture group name") if @group_names.key?(name)
            open_capture
            @group_names[name] = @group_count
          end
        else
          read_modifiers_group
        end
      end

      def open_capture
        @group_count += 1
        emit("(")
        @groups << Group.new(:capture, dot_all?)
      end

      def dot_all?
        !@groups.empty? && @groups.last.dot_all
      end

      # `(?ims-ims:…)`. `i` is Onigmo's `i`; `s` is dotAll, applied to `.` by
      # hand because Onigmo spells it `m`, which is something else in
      # ECMAScript; `m` (multiline anchors) has no scoped Onigmo form.
      def read_modifiers_group
        add = read_modifier_flags
        remove = ""
        if peek == "-"
          advance
          remove = read_modifier_flags
        end
        fail_syntax("Invalid group") unless peek == ":"
        advance
        fail_syntax("Invalid regular expression modifiers") if add.empty? && remove.empty?
        fail_syntax("Repeated regular expression modifier") unless (add.chars & remove.chars).empty?
        if add.include?("m") || remove.include?("m")
          fail_syntax("The multiline modifier has no Onigmo equivalent")
        end
        onigmo_add = add.include?("i") ? "i" : ""
        onigmo_remove = remove.include?("i") ? "-i" : ""
        emit("(?#{onigmo_add}#{onigmo_remove}:")
        dot_all = if add.include?("s")
          true
        elsif remove.include?("s")
          false
        else
          dot_all?
        end
        @groups << Group.new(:noncapture, dot_all)
      end

      def read_modifier_flags
        flags = +""
        while (c = peek) && "ims".include?(c)
          fail_syntax("Repeated regular expression modifier") if flags.include?(c)
          flags << c
          advance
        end
        flags
      end

      def read_group_close
        group = @groups.pop
        fail_syntax("Unmatched ')'") unless group
        emit(")")
        @quantifiable = group.kind != :lookaround
      end

      def read_quantifier(kind)
        fail_syntax("Nothing to repeat") unless @quantifiable
        emit(kind)
        if peek == "?"
          advance
          emit("?")
        end
        @quantifiable = false
      end

      def read_brace_quantifier
        match = @source[@pos..].match(/\A\{(\d+)(?:(,)(\d*))?\}/)
        fail_syntax("Incomplete quantifier") unless match
        min = match[1].to_i
        if match[2] && !match[3].empty? && match[3].to_i < min
          fail_syntax("numbers out of order in {} quantifier")
        end
        advance(match[0].length)
        read_quantifier(match[0])
      end

      # AtomEscape: the `\` has been consumed.
      def read_atom_escape
        c = peek
        fail_syntax("\\ at end of pattern") unless c
        case c
        when "b"
          advance
          emit(WORD_BOUNDARY)
          @quantifiable = false
        when "B"
          advance
          emit(NON_WORD_BOUNDARY)
          @quantifiable = false
        when "k"
          advance
          fail_syntax("Invalid named reference") unless peek == "<"
          advance
          emit(Backref.new(read_group_name, nil))
          @quantifiable = true
        when "1".."9"
          digits = @source[@pos..][/\A\d+/]
          advance(digits.length)
          emit(Backref.new(nil, digits.to_i))
          @quantifiable = true
        else
          if (fragment = read_class_escape_set)
            emit(fragment)
          else
            emit(literal(read_character_escape(in_class: false)))
          end
          @quantifiable = true
        end
      end

      # `\d` `\D` `\w` `\W` `\s` `\S` `\p{…}` `\P{…}`, as something that can
      # stand alone or inside a class; nil when the escape is not one of them.
      def read_class_escape_set
        case peek
        when "d", "D", "w", "W"
          fragment = "\\#{peek}"
          advance
          fragment
        when "s"
          advance
          "[#{WHITE_SPACE}]"
        when "S"
          advance
          "[^#{WHITE_SPACE}]"
        when "p", "P"
          negated = peek == "P"
          advance
          fail_syntax("Invalid property name") unless peek == "{"
          advance
          body = read_until("}")
          "\\#{negated ? "P" : "p"}{#{property_name(body, negated)}}"
        end
      end

      def property_name(body, negated)
        name, value = body.split("=", 2)
        if value
          fail_syntax("Invalid property name") unless VALUED_PROPERTY_NAMES[name] && !value.empty?
          return value
        end
        return name if LONE_PROPERTY_NAMES[name]

        if STRING_PROPERTY_NAMES[name]
          fail_syntax("Invalid property name") if negated
          fail_syntax("The property of strings \\p{#{name}} has no Onigmo equivalent")
        end
        fail_syntax("Invalid property name")
      end

      # CharacterEscape and the identity escapes: returns the code point, to
      # be rendered for wherever it lands. A lone surrogate comes back as is;
      # `literal` and `class_char` know what to do with it.
      def read_character_escape(in_class:)
        c = peek
        advance
        case c
        when "t" then 0x09
        when "n" then 0x0A
        when "v" then 0x0B
        when "f" then 0x0C
        when "r" then 0x0D
        when "0"
          fail_syntax("Invalid decimal escape") if peek&.match?(/\d/)
          0x00
        when "c"
          control = peek
          fail_syntax("Invalid escape") unless control&.match?(/[A-Za-z]/)
          advance
          control.ord % 32
        when "x"
          hex = @source[@pos, 2]
          fail_syntax("Invalid escape") unless hex&.match?(/\A\h{2}\z/)
          advance(2)
          hex.to_i(16)
        when "u"
          read_unicode_escape
        when "b"
          fail_syntax("Invalid escape") unless in_class
          0x08
        else
          escapable = SYNTAX_CHARACTERS.include?(c) || c == "/" ||
            (in_class && CLASS_RESERVED_PUNCTUATORS.include?(c))
          fail_syntax("Invalid escape") unless escapable
          c.ord
        end
      end

      # `\u{…}` or `\uXXXX`, the `u` consumed. A high surrogate followed by
      # `\uDC00`-`\uDFFF` is one code point.
      def read_unicode_escape
        if peek == "{"
          advance
          hex = read_until("}")
          fail_syntax("Invalid Unicode escape") unless hex.match?(/\A\h{1,6}\z/) && hex.to_i(16) <= 0x10FFFF
          return hex.to_i(16)
        end
        code = read_four_hex
        if code.between?(0xD800, 0xDBFF) && @source[@pos, 2] == "\\u"
          low = @source[@pos + 2, 4]
          if low&.match?(/\A\h{4}\z/) && low.to_i(16).between?(0xDC00, 0xDFFF)
            advance(6)
            return 0x10000 + ((code - 0xD800) << 10) + (low.to_i(16) - 0xDC00)
          end
        end
        code
      end

      def surrogate?(code)
        code.between?(0xD800, 0xDFFF)
      end

      def read_four_hex
        hex = @source[@pos, 4]
        fail_syntax("Invalid Unicode escape") unless hex&.match?(/\A\h{4}\z/)
        advance(4)
        hex.to_i(16)
      end

      def read_until(terminator)
        body = +""
        until peek == terminator
          fail_syntax("Unterminated escape") if eof?
          body << peek
          advance
        end
        advance
        body
      end

      # GroupName: `<` was consumed; reads through `>`. RegExpIdentifierName
      # is ID_Start / ID_Continue plus `$` and `_`, with `\u` escapes allowed.
      def read_group_name
        name = +""
        until peek == ">"
          fail_syntax("Invalid capture group name") if eof?
          c = peek
          advance
          if c == "\\"
            fail_syntax("Invalid capture group name") unless peek == "u"
            advance
            code = read_unicode_escape
            fail_syntax("Invalid capture group name") if surrogate?(code)
            c = code.chr(Encoding::UTF_8)
          end
          valid = if name.empty?
            c.match?(/[\p{ID_Start}$_]/)
          else
            c.match?(/[\p{ID_Continue}$\u200c\u200d]/)
          end
          fail_syntax("Invalid capture group name") unless valid
          name << c
        end
        advance
        fail_syntax("Invalid capture group name") if name.empty?
        name
      end

      def resolve_backref(backref)
        number = backref.number || @group_names[backref.name]
        fail_syntax("Invalid named capture referenced") unless number
        fail_syntax("Invalid escape") if number > @group_count
        # A reference to a group that has not captured matches the empty
        # string in ECMAScript and fails in Onigmo; the conditional asks.
        "(?(#{number})\\k<#{number}>|)"
      end

      # ---- inside a class ----------------------------------------------------

      # ClassSetExpression: the `[` was consumed; reads through `]` and returns
      # the Onigmo class. Nested classes come back through the same method.
      # An empty class is `[^\p{Any}]`, so `[]` matches nothing and `[^]`
      # everything, and either nests without special cases.
      def read_class
        negated = peek == "^"
        advance if negated
        prefix = negated ? "[^" : "["
        if peek == "]"
          advance
          return negated ? "[\\p{Any}]" : UNMATCHABLE_SET
        end

        first = read_class_operand
        case class_operator
        when "&&"
          "#{prefix}#{read_class_chain("&&", first) { |operand| operand }}]"
        when "--"
          "#{prefix}#{read_class_chain("--", first) { |operand| "[^#{operand}]" }}]"
        else
          "#{prefix}#{read_class_union(first)}]"
        end
      end

      def class_operator
        two = @source[@pos, 2]
        two if two == "&&" || two == "--"
      end

      # ClassIntersection / ClassSubtraction: `first` is already read; every
      # further operand must be joined by the same `operator`. The block
      # renders the right-hand operands, which is where subtraction turns into
      # intersection with a complement.
      def read_class_chain(operator, first)
        pieces = [render_class_operand(first)]
        while class_operator == operator
          advance(2)
          fail_syntax("Invalid set operation in character class") if class_operator || peek == operator[0]
          pieces << yield(render_class_operand(read_class_operand))
        end
        fail_syntax("Invalid set operation in character class") if class_operator
        fail_syntax("Unterminated character class") unless peek == "]"
        advance
        pieces.join("&&")
      end

      # ClassUnion: operands and ranges until `]`. `&&` and `--` may not appear
      # once the class is a union.
      def read_class_union(first)
        pieces = +""
        operand = first
        loop do
          if operand[0] == :char && peek == "-" && peek(1) != "-"
            advance
            upper = read_class_operand
            fail_syntax("Invalid character class") unless upper[0] == :char
            fail_syntax("Range out of order in character class") if upper[1] < operand[1]
            pieces << class_range(operand[1], upper[1])
          else
            pieces << render_class_operand(operand)
          end
          fail_syntax("Invalid set operation in character class") if class_operator
          fail_syntax("Unterminated character class") if eof?
          break if peek == "]"

          operand = read_class_operand
        end
        advance
        pieces.empty? ? UNMATCHABLE_SET : pieces
      end

      # A range whose end is a lone surrogate covers the scalar values on the
      # other side of the surrogate block, and one that lies inside the block
      # covers nothing.
      def class_range(lower, upper)
        lower = 0xE000 if surrogate?(lower)
        upper = 0xD7FF if surrogate?(upper)
        return "" if lower > upper

        "#{class_char(lower)}-#{class_char(upper)}"
      end

      # ClassSetOperand: [:char, Integer] for a single code point, [:set,
      # String] for something already in Onigmo class form (`\d`, `\p{Lu}`,
      # `[…]`).
      def read_class_operand
        c = peek
        fail_syntax("Unterminated character class") unless c
        case c
        when "["
          advance
          [:set, read_class]
        when "\\"
          advance
          fail_syntax("\\q{...} has no Onigmo equivalent") if peek == "q" && peek(1) == "{"
          if (fragment = read_class_escape_set)
            [:set, fragment]
          else
            [:char, read_character_escape(in_class: true)]
          end
        else
          fail_syntax("Invalid character in character class") if CLASS_SYNTAX_CHARACTERS.include?(c)
          if CLASS_DOUBLE_PUNCTUATORS.include?(c) && peek(1) == c
            fail_syntax("Invalid set operation in character class")
          end
          advance
          [:char, c.ord]
        end
      end

      def render_class_operand(operand)
        operand[0] == :char ? class_char(operand[1]) : operand[1]
      end

      # A code point inside an Onigmo class, escaped where Onigmo would read
      # it as syntax. Control characters are spelled out so the source stays
      # printable.
      def class_char(code)
        return UNMATCHABLE_SET if surrogate?(code)
        return control_escape(code) if control?(code)

        c = code.chr(Encoding::UTF_8)
        "[]\\^-&".include?(c) ? "\\#{c}" : c
      end

      # A code point outside a class.
      def literal(code)
        return UNMATCHABLE if surrogate?(code)
        return control_escape(code) if control?(code)

        Regexp.escape(code.chr(Encoding::UTF_8))
      end

      def control?(code)
        code < 0x20 || code == 0x7f
      end

      def control_escape(code)
        format("\\x%02X", code)
      end
    end
  end
end
