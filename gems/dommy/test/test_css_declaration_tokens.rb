# frozen_string_literal: true

require_relative "test_helper"

# A declaration block is read in tokens (css-syntax-3 §5.4.5): a `;` or `:`
# inside a string, a function, a {} block or an escape is part of a value, and
# a comment is no token at all. The same holds where var() is looked for.
class TestCssDeclarationTokens < Minitest::Test
  CASCADE = Dommy::Internal::CSS::Cascade

  def style_of(declarations)
    doc = Dommy.parse("<p id=x></p>").document
    element = doc.get_element_by_id("x")
    element.set_attribute("style", declarations)
    element.style
  end

  def test_semicolons_and_colons_inside_a_value_do_not_split_it
    {
      'content: ";"; color: red' => ["content", '";"'],
      'content: "a:b"; color: red' => ["content", '"a:b"'],
      "background-image: url(data:image/png;base64,AA); color: red" =>
        ["background-image", "url(data:image/png;base64,AA)"],
      'font-family: "a;b", serif; color: red' => ["font-family", '"a;b", serif'],
      "--x: {a;b}; color: red" => ["--x", "{a;b}"],
      "--x: {a:b}; color: red" => ["--x", "{a:b}"],
      'content: a\;b; color: red' => ["content", 'a\;b'],
    }.each do |declarations, (property, value)|
      style = style_of(declarations)

      assert_equal value, style.get_property_value(property), declarations
      assert_equal "red", style.get_property_value("color"), declarations
    end
  end

  # An unquoted url is one token (§4.3.6): a `/*` in it opens no comment and
  # a quote no string, whatever the case of `url`. A quoted one is a function
  # holding a string.
  def test_an_unquoted_url_holds_no_comment_or_string
    {
      "background-image: url(a/*b.png); color: red" => ["background-image", "url(a/*b.png)"],
      "background-image: url(it's.png); color: red" => ["background-image", "url(it's.png)"],
      "background-image: URL( x;y ); color: red" => ["background-image", "URL( x;y )"],
      'background-image: url("a;b"); color: red' => ["background-image", 'url("a;b")'],
      "--img: url(x/*y.png); color: red" => ["--img", "url(x/*y.png)"],
    }.each do |declarations, (property, value)|
      style = style_of(declarations)

      assert_equal value, style.get_property_value(property), declarations
      assert_equal "red", style.get_property_value("color"), declarations
    end

    doc = Dommy.parse("<style>#u { background-image: url(x/*y.png) }</style><p id=u></p>").document
    assert_equal "url(x/*y.png)", CASCADE.computed_style(doc.get_element_by_id("u"))["background-image"]
  end

  def test_comments_are_no_tokens
    assert_equal "red", style_of("color: red /* ; color: blue */").get_property_value("color")
    assert_equal "red", style_of("/* x: y; */ color: red").get_property_value("color")
    assert_equal "red", style_of("color: /* c */ red").get_property_value("color")
    assert_equal "1px solid", style_of("--b: 1px/**/solid").get_property_value("--b")
    assert_equal "calc(1px + 2px)", style_of("width: calc(1px /* ) */ + 2px)").get_property_value("width")
  end

  # A custom property's value may be empty — nothing but a comment or
  # whitespace — and the declaration is kept. Any other property needs a value.
  def test_a_custom_property_may_be_empty
    ["--x: /* c */", "--x:;", "--x: "].each do |declarations|
      style = style_of(declarations)

      assert_equal 1, style.length, declarations
      assert_equal "", style.get_property_value("--x"), declarations
    end
    assert_equal 0, style_of("color: /* c */").length
  end

  def test_var_inside_a_string_or_a_comment_is_text
    doc = Dommy.parse(<<~HTML).document
      <style>
        :root { --c: red; --w: 10px }
        #s { content: "var(--c)" }
        #f { width: var(--missing, /* ) */ 7px) }
        #q { font-family: var(--missing, "a,b") }
        #t { --t: 1px /* c */ }
      </style>
      <p id="s">x</p><p id="f">x</p><p id="q">x</p><p id="t">x</p>
    HTML

    assert_equal '"var(--c)"', CASCADE.computed_style(doc.get_element_by_id("s"))["content"]
    assert_equal "7px", CASCADE.computed_style(doc.get_element_by_id("f"))["width"]
    assert_equal '"a,b"', CASCADE.computed_style(doc.get_element_by_id("q"))["font-family"]
    assert_equal "1px", CASCADE.computed_style(doc.get_element_by_id("t"))["--t"]
  end

  # Parse-time validation reads var() the same way: an unclosed `var(` inside
  # a string keeps the declaration.
  def test_a_var_in_a_string_does_not_invalidate_the_declaration
    style = style_of('content: "var(--"; --x: "var("; color: red')

    assert_equal '"var(--"', style.get_property_value("content")
    assert_equal '"var("', style.get_property_value("--x")
    assert_equal "red", style.get_property_value("color")
  end

  # The cycle check reads each var()'s name wherever the call stands in the
  # value, after other text or another var().
  def test_a_cycle_through_a_var_after_other_text
    doc = Dommy.parse(<<~HTML).document
      <style>#c { --a: 1px var(--b); --b: solid var(--a); --ok: 2px var(--d, 3px); width: var(--a, 9px) }</style>
      <p id="c">x</p>
    HTML
    style = CASCADE.computed_style(doc.get_element_by_id("c"))

    assert_equal "9px", style["width"]
    assert_equal "2px 3px", style["--ok"]
  end
end
