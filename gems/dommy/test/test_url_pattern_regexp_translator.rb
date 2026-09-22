# frozen_string_literal: true

require_relative "test_helper"

# ECMAScript ("v" flag) -> Onigmo. Each group of tests names one difference
# between the two dialects, checks the Onigmo source the translator writes,
# and then checks that the compiled Regexp behaves the way `new RegExp(src,
# "v")` does.
class TestURLPatternRegExpTranslator < Minitest::Test
  Translator = Dommy::URLPattern::RegExpTranslator

  def translate(source)
    Translator.new(source).translate
  end

  def compile(source, ignore_case: false)
    Translator.compile(source, ignore_case: ignore_case)
  end

  def assert_rejected(source, message = nil)
    error = assert_raises(Translator::Error) { compile(source) }
    assert_kind_of(Dommy::Bridge::TypeError, error)
    assert_includes(error.message, message) if message
  end

  # --- pass-through -----------------------------------------------------

  def test_plain_pattern_is_unchanged
    assert_equal("abc", translate("abc"))
    assert_equal("(?:a|b)+c*d??e{2,3}", translate("(?:a|b)+c*d??e{2,3}"))
    assert_equal("\\d\\D\\w\\W", translate("\\d\\D\\w\\W"))
    assert_equal("\\(\\)\\[\\]\\{\\}\\|\\.\\*\\+\\?\\^\\$\\\\/", translate("\\(\\)\\[\\]\\{\\}\\|\\.\\*\\+\\?\\^\\$\\\\\\/"))
  end

  def test_empty_pattern
    assert_equal("", translate(""))
    assert(compile("").match?(""))
  end

  def test_lookaround_passes_through
    assert_equal("(?=a)(?!b)(?<=c)(?<!d)", translate("(?=a)(?!b)(?<=c)(?<!d)"))
  end

  def test_unicode_escapes
    assert(compile("\\u{1F600}").match?("\u{1F600}"))
    assert(compile("\\u0041").match?("A"))
    assert(compile("\\x41").match?("A"))
    assert(compile("\\cA").match?("\u0001"))
    assert(compile("\\0").match?("\u0000"))
    assert(compile("\\t\\n\\v\\f\\r").match?("\t\n\u000b\f\r"))
  end

  # --- anchors ----------------------------------------------------------

  def test_anchors_bind_the_whole_input_not_a_line
    assert_equal("\\Aab\\z", translate("^ab$"))
    refute(compile("^ab$").match?("ab\ncd"))
    assert(compile("^ab$").match?("ab"))
  end

  # --- dot ---------------------------------------------------------------

  def test_dot_excludes_every_line_terminator
    regexp = compile("^.$")
    assert(regexp.match?("a"))
    refute(regexp.match?("\n"))
    refute(regexp.match?("\r"))
    refute(regexp.match?("\u2028"))
    refute(regexp.match?("\u2029"))
  end

  def test_dot_all_modifier_group
    regexp = compile("^(?s:.)(.)$")
    assert(regexp.match?("\na"))
    refute(regexp.match?("a\n"))
    assert(compile("^(?s:(?-s:.))$").match?("a"))
    refute(compile("^(?s:(?-s:.))$").match?("\n"))
  end

  # --- \s ----------------------------------------------------------------

  def test_white_space_is_ecmascripts_set
    regexp = compile("^\\s$")
    ["\u00a0", "\ufeff", "\u2028", "\u3000", " ", "\t"].each do |char|
      assert(regexp.match?(char), "U+#{char.ord.to_s(16)}")
    end
    refute(regexp.match?("\u0085")) # NEL is Unicode White_Space but not ECMAScript WhiteSpace
    refute(compile("^\\S$").match?("\u00a0"))
    assert(compile("^[\\s\\d]+$").match?("1\u00a0"))
    assert(compile("^[^\\s]$").match?("x"))
  end

  # --- \b ----------------------------------------------------------------

  def test_word_boundary_is_ascii
    assert(compile("\\bab\\b").match?("ab"))
    assert(compile("\\bab\\b").match?("\u00e9ab\u00e9")) # e-acute is not a word char
    refute(compile("\\bab\\b").match?("xab"))
    assert(compile("a\\Bb").match?("ab"))
    refute(compile("a\\B\u00e9").match?("a\u00e9"))
  end

  def test_word_boundary_is_not_quantifiable
    assert_rejected("\\b+", "Nothing to repeat")
  end

  # --- groups and backreferences -----------------------------------------

  def test_named_group_keeps_numbered_captures
    assert_equal("(a)(b)", translate("(?<x>a)(b)"))
    match = compile("^(?<x>a)(b)$").match("ab")
    assert_equal(["a", "b"], match.captures)
  end

  def test_named_backreference_becomes_a_number
    assert_equal("(a)(?(1)\\k<1>|)", translate("(?<x>a)\\k<x>"))
    assert(compile("^(?<x>a)\\k<x>$").match?("aa"))
    refute(compile("^(?<x>a)\\k<x>$").match?("ab"))
  end

  def test_numbered_backreference
    assert_equal("(a)(?(1)\\k<1>|)", translate("(a)\\1"))
    assert(compile("^(a)\\1$").match?("aa"))
    refute(compile("^(a)\\1$").match?("ab"))
  end

  def test_reference_to_a_group_that_has_not_captured_matches_the_empty_string
    assert(compile("^\\k<x>(?<x>a)$").match?("a"))
    assert(compile("^\\1(a)$").match?("a"))
    assert(compile("^(?:(a)|b)\\1$").match?("b"))
    assert(compile("^(?:(a)|b)\\1$").match?("aa"))
    refute(compile("^(?:(a)|b)\\1$").match?("ab"))
  end

  def test_backreference_to_a_missing_group_is_rejected
    assert_rejected("(a)\\2")
    assert_rejected("\\k<nope>(?<x>a)", "Invalid named capture")
    assert_rejected("\\k<x>")
  end

  def test_group_name_grammar
    assert_equal("(a)", translate("(?<$_\u00e9>a)"))
    assert_equal("(a)(?(1)\\k<1>|)", translate("(?<\\u0041>a)\\k<A>"))
    assert_rejected("(?<\\uD800>a)", "Invalid capture group name")
    assert_rejected("(?<1a>a)", "Invalid capture group name")
    assert_rejected("(?<>a)", "Invalid capture group name")
    assert_rejected("(?<x>a)(?<x>b)", "Duplicate capture group name")
  end

  def test_group_bracket_errors
    assert_rejected("(a", "Unterminated group")
    assert_rejected("a)", "Unmatched")
    assert_rejected("(?R)", "Invalid group")
    assert_rejected("(?#comment)", "Invalid group")
    assert_rejected("(?>a)", "Invalid group")
    assert_rejected("(?P<x>a)", "Invalid group")
  end

  def test_modifier_groups
    assert_equal("(?i:a)", translate("(?i:a)"))
    assert_equal("(?-i:a)", translate("(?-i:a)"))
    assert_equal("(?i:a)", translate("(?is:a)"))
    assert(compile("^(?i:a)b$").match?("Ab"))
    refute(compile("^(?i:a)b$").match?("AB"))
    assert(compile("^(?-i:a)b$", ignore_case: true).match?("aB"))
    refute(compile("^(?-i:a)b$", ignore_case: true).match?("Ab"))
    assert_equal("(?i:a)", translate("(?is-:a)"))
    assert_rejected("(?ii:a)", "Repeated")
    assert_rejected("(?i-i:a)", "Repeated")
    assert_rejected("(?-:a)", "modifiers")
    assert_rejected("(?m:a)", "multiline")
  end

  # --- quantifiers ---------------------------------------------------------

  def test_quantifier_errors_ecmascript_reports
    assert_rejected("a*+", "Nothing to repeat")
    assert_rejected("a**", "Nothing to repeat")
    assert_rejected("*a", "Nothing to repeat")
    assert_rejected("a|*", "Nothing to repeat")
    assert_rejected("(?=a)*", "Nothing to repeat")
    assert_rejected("a{3,2}", "out of order")
    assert_rejected("a{", "Incomplete quantifier")
    assert_rejected("a{,3}", "Incomplete quantifier")
    assert_rejected("a}", "Lone quantifier")
    assert_rejected("a]", "Lone quantifier")
  end

  def test_brace_quantifiers
    assert_equal("a{2}b{3,}c{1,4}?", translate("a{2}b{3,}c{1,4}?"))
    assert(compile("^a{2}$").match?("aa"))
  end

  def test_quantified_group_is_still_quantifiable_after_close
    assert_equal("(?:ab)+", translate("(?:ab)+"))
    assert_equal("(?<=a)b", translate("(?<=a)b"))
  end

  # --- escapes ECMAScript rejects -----------------------------------------

  def test_identity_escapes_are_limited_to_syntax_characters
    assert_rejected("\\H", "Invalid escape")
    assert_rejected("\\h", "Invalid escape")
    assert_rejected("\\m", "Invalid escape")
    assert_rejected("\\A", "Invalid escape")
    assert_rejected("\\z", "Invalid escape")
    assert_rejected("\\a", "Invalid escape")
    assert_rejected("\\e", "Invalid escape")
    assert_rejected("\\-", "Invalid escape")
    assert_rejected("\\ ", "Invalid escape")
    assert_rejected("a\\", "end of pattern")
  end

  def test_malformed_numeric_escapes
    assert_rejected("\\x4", "Invalid escape")
    assert_rejected("\\u004", "Invalid Unicode escape")
    assert_rejected("\\u{110000}", "Invalid Unicode escape")
    assert_rejected("\\u{}", "Invalid Unicode escape")
    assert_rejected("\\c1", "Invalid escape")
    assert_rejected("\\01", "Invalid decimal escape")
  end

  def test_surrogate_pair_is_one_code_point
    assert_equal("\u{1F600}", translate("\\uD83D\\uDE00"))
    assert(compile("^\\uD83D\\uDE00$").match?("\u{1F600}"))
  end

  def test_lone_surrogate_matches_nothing
    # A UTF-16 code unit no UTF-8 string can hold.
    assert_equal("(?!)", translate("\\uD83D"))
    assert_equal("(?!)", translate("\\u{DC00}"))
    refute(compile("\\uD83D").match?("\u{1F600}"))
    assert(compile("^(?:\\uD83D|a)$").match?("a"))
    assert_equal("[[^\\p{Any}]a]", translate("[\\uD83Da]"))
    assert(compile("^[\\uD83Da]$").match?("a"))
    assert_equal("[[^\\p{Any}]]", translate("[\\uD800-\\uDFFF]"))
    assert_equal("[\uE000-\u{10000}]", translate("[\\uD800-\\u{10000}]"))
    assert(compile("^[\\u0000-\\uDFFF]$").match?("\uD7FF"))
    assert_rejected("[\\uDFFF-\\uD800]", "Range out of order")
  end

  # --- properties -----------------------------------------------------------

  def test_property_names_and_values
    assert_equal("\\p{Lu}\\P{L}\\p{Alphabetic}", translate("\\p{Lu}\\P{L}\\p{Alphabetic}"))
    assert_equal("\\p{Greek}", translate("\\p{Script=Greek}"))
    assert_equal("\\p{Grek}", translate("\\p{sc=Grek}"))
    assert_equal("\\P{Greek}", translate("\\P{Script_Extensions=Greek}"))
    assert_equal("\\p{Lu}", translate("\\p{General_Category=Lu}"))
    assert_equal("\\p{Letter}", translate("\\p{gc=Letter}"))
    assert(compile("^\\p{Script=Greek}$").match?("\u03b1"))
    assert(compile("^[\\p{Lu}\\d]+$").match?("A1"))
  end

  def test_property_names_ecmascript_rejects
    assert_rejected("\\p{Greek}", "Invalid property name") # a Script needs Script=
    assert_rejected("\\p{Nope}", "Invalid property name")
    assert_rejected("\\p{Block=Basic_Latin}", "Invalid property name")
    assert_rejected("\\p{Script=}", "Invalid property name")
    assert_rejected("\\pL", "Invalid property name")
    assert_rejected("\\p{Script=Nope}") # Onigmo rejects the value
    assert_rejected("\\P{RGI_Emoji}", "Invalid property name")
    assert_rejected("\\p{RGI_Emoji}", "no Onigmo equivalent")
  end

  # --- classes --------------------------------------------------------------

  def test_class_union
    assert_equal("[abc0-9\\-]", translate("[abc0-9\\-]"))
    assert_equal("[^\\^\\]\\[\\&]", translate("[^\\^\\]\\[\\&]"))
    assert_equal("[.$]", translate("[.$]"))
    assert(compile("^[.$]$").match?("."))
    refute(compile("^[.$]$").match?("a"))
    assert(compile("^[a-c]$").match?("b"))
    assert(compile("^[^a-c]$").match?("d"))
  end

  def test_class_escapes
    assert_equal("[\\x08\\d\\p{Lu}\\-\\&]", translate("[\\b\\d\\p{Lu}\\-\\&]"))
    assert(compile("^[\\b]$").match?("\u0008"))
    assert(compile("^[\\.\\/]$").match?("/"))
    assert(compile("^[\\u0041-\\u{43}]$").match?("B"))
  end

  def test_empty_classes
    assert_equal("[^\\p{Any}]", translate("[]"))
    assert_equal("[\\p{Any}]", translate("[^]"))
    refute(compile("[]").match?("a"))
    assert(compile("^[^]$").match?("\n"))
    assert(compile("^[a[]]$").match?("a"))
  end

  def test_nested_class_and_intersection
    assert_equal("[[a-z][0-9]]", translate("[[a-z][0-9]]"))
    assert_equal("[\\d&&[0-1]]", translate("[\\d&&[0-1]]"))
    assert(compile("^[\\d&&[0-1]]$").match?("0"))
    refute(compile("^[\\d&&[0-1]]$").match?("3"))
    assert(compile("^[[a-z]&&[^aeiou]&&[a-m]]$").match?("b"))
    refute(compile("^[[a-z]&&[^aeiou]&&[a-m]]$").match?("n"))
  end

  def test_class_subtraction_becomes_intersection_with_a_complement
    assert_equal("[[a-z]&&[^a]]", translate("[[a-z]--a]"))
    assert_equal("[^\\p{L}&&[^[a-z]]&&[^q]]", translate("[^\\p{L}--[a-z]--q]"))
    assert(compile("^[[a-z]--a]$").match?("z"))
    refute(compile("^[[a-z]--a]$").match?("a"))
    assert(compile("^[^[a-z]--a]$").match?("a"))
    refute(compile("^[^[a-z]--a]$").match?("z"))
    assert(compile("^[\\p{L}--[a-z]--Q]$").match?("R"))
    refute(compile("^[\\p{L}--[a-z]--Q]$").match?("Q"))
  end

  def test_class_syntax_ecmascript_rejects
    assert_rejected("[a-]", "Invalid character in character class")
    assert_rejected("[-a]", "Invalid character in character class")
    assert_rejected("[(]", "Invalid character in character class")
    assert_rejected("[|]", "Invalid character in character class")
    assert_rejected("[a-\\d]", "Invalid character class")
    assert_rejected("[\\d-a]", "Invalid character in character class")
    assert_rejected("[z-a]", "Range out of order")
    assert_rejected("[a", "Unterminated character class")
    assert_rejected("[a&&b--c]", "Invalid set operation")
    assert_rejected("[ab&&c]", "Invalid set operation")
    assert_rejected("[a&&&b]", "Invalid set operation")
    assert_rejected("[a&&]", "Invalid character in character class")
    assert_rejected("[&&a]", "Invalid set operation")
    assert_rejected("[a..b]", "Invalid set operation")
    assert_rejected("[^^^]", "Invalid set operation")
    assert_rejected("[\\q{ab}]", "no Onigmo equivalent")
  end

  # --- ignoreCase and Onigmo's own limits -----------------------------------

  def test_ignore_case_flag
    assert(compile("^abc$", ignore_case: true).match?("ABC"))
    refute(compile("^abc$").match?("ABC"))
  end

  def test_onigmo_rejections_surface_as_the_same_error
    assert_rejected("(?<=a+)b", "look-behind")
  end

  # --- what the URLPattern spec generates -----------------------------------

  def test_a_generated_component_pattern
    # `/users/:id` as "generate a regular expression and name list" writes it.
    source = "^/users(?:/([^\\/#\\?]+?))[\\/#\\?]?$"
    assert_equal("\\A/users(?:/([^/#?]+?))[/#?]?\\z", translate(source))
    match = compile(source).match("/users/42")
    assert_equal("42", match[1])
    assert_nil(compile(source).match("/users/42/x"))
  end
end
