# frozen_string_literal: true

require_relative "test_helper"

# The cascade reads an element's style attribute with the parser `el.style`
# reads it with, so the computed style and the CSSOM agree on what it says.
class TestInlineStyleCascade < Minitest::Test
  def computed(style)
    doc = Dommy.parse(%(<p id="p" style='#{style}'>t</p>)).document
    Dommy::Internal::CSS::Cascade.computed_style(doc.get_element_by_id("p"))
  end

  def test_a_semicolon_inside_a_string_or_a_url_does_not_end_a_declaration
    style = computed(%(--x: "a;color:red"; background-image: url(data:image/png;base64,AAA=)))
    assert_equal [%("a;color:red"), "url(data:image/png;base64,AAA=)"], [style["--x"], style["background-image"]]
    assert_equal "rgb(0, 0, 0)", style["color"]
  end

  def test_a_commented_out_declaration_is_not_read
    assert_equal "rgb(0, 0, 0)", computed("/* color: blue; */ display: block")["color"]
  end

  def test_an_important_declaration_beats_a_later_normal_one
    assert_equal "rgb(0, 0, 255)", computed("color: blue !important; color: red")["color"]
  end

  # CSSOM's camel-cased and webkit-cased attribute names, and the Compat
  # Standard's -webkit- legacy name aliases.
  def test_css_float_and_webkit_aliases
    el = Dommy.parse("<p>t</p>").document.query_selector("p")
    el.style.__js_set__("cssFloat", "left")
    el.style.__js_set__("webkitFilter", "blur(1px)")
    assert_equal "float: left; filter: blur(1px);", el.get_attribute("style")
    assert_equal "blur(1px)", el.style.__js_get__("webkitFilter")
  end

  # A sheet's -webkit- legacy name alias declares the unprefixed property,
  # so it takes part in the cascade (later wins, `!important` beats) and
  # serializes unprefixed, as in a style attribute.
  def test_webkit_aliases_in_a_stylesheet
    doc = Dommy.parse(<<~HTML).document
      <style>#a{-webkit-transform: rotate(1deg)} #b{transform: a; -webkit-transform: b} #c{-webkit-filter: x !important; filter: y}</style>
      <p id="a"></p><p id="b"></p><p id="c"></p>
    HTML
    style = ->(id) { Dommy::Internal::CSS::Cascade.computed_style(doc.get_element_by_id(id)) }
    assert_equal "rotate(1deg)", style.("a")["transform"]
    assert_equal "b", style.("b")["transform"]
    assert_equal "x", style.("c")["filter"]
    rule = doc.query_selector("style").__js_get__("sheet").__js_get__("cssRules").__js_call__("item", [0])
    assert_equal "#a { transform: rotate(1deg); }", rule.__js_get__("cssText")
  end

  # Property names are ASCII case-insensitive only: the Kelvin sign is not a
  # `k`, in a sheet, a style attribute or CSSOM.
  def test_property_names_fold_ascii_only
    name = "bac\u212Aground-color"
    doc = Dommy.parse(%(<style>#s{#{name}: blue}</style><p id="s"></p><p id="a" style="#{name}: blue"></p>)).document
    style = ->(id) { Dommy::Internal::CSS::Cascade.computed_style(doc.get_element_by_id(id)) }
    assert_equal "rgba(0, 0, 0, 0)", style.("s")["background-color"]
    assert_equal "rgba(0, 0, 0, 0)", style.("a")["background-color"]
    assert_equal "", doc.get_element_by_id("a").style.get_property_value("background-color")
  end

  # A float, an absolutely positioned box and a flex item compute an
  # inline-level display to its block-level form.
  def test_blockification_of_the_computed_display
    doc = Dommy.parse(%(<div style="display:flex"><span id="a">x</span></div><span id="b" style="float:left">y</span><span id="c" style="position:absolute;display:inline-flex">z</span>)).document
    display = ->(id) { Dommy::Internal::CSS::Cascade.computed_style(doc.get_element_by_id(id))["display"] }
    assert_equal %w[block block flex], %w[a b c].map(&display)
  end

  # A table part blockified becomes a block, and the root element's
  # `display: contents` computes to `block`; a table part in a table stays.
  def test_blockification_of_table_parts_and_a_contents_root
    doc = Dommy.parse(<<~HTML).document
      <div style="display:flex"><span id="a" style="display:table-cell">a</span></div>
      <span id="b" style="float:left;display:table-row">b</span>
      <span id="c" style="position:absolute;display:table-caption">c</span>
      <table><tr><td id="d">d</td></tr></table>
    HTML
    display = ->(id) { Dommy::Internal::CSS::Cascade.computed_style(doc.get_element_by_id(id))["display"] }
    assert_equal %w[block block block table-cell], %w[a b c d].map(&display)

    root = Dommy.parse("<!doctype html><html style='display:contents'><body></body></html>").document.document_element
    assert_equal "block", Dommy::Internal::CSS::Cascade.computed_style(root)["display"]
  end

  # Inline ruby blockified is block ruby, and a ruby part a block.
  def test_blockification_of_ruby
    doc = Dommy.parse(<<~HTML).document
      <span id="a" style="float:left;display:ruby">a</span>
      <div style="display:flex"><span id="b" style="display:ruby-text">b</span></div>
      <span id="c" style="display:ruby">c</span>
    HTML
    display = ->(id) { Dommy::Internal::CSS::Cascade.computed_style(doc.get_element_by_id(id))["display"] }
    assert_equal ["block ruby", "block", "ruby"], %w[a b c].map(&display)
  end

  # The keywords that decide it are ASCII case-insensitive: `float: NONE` is
  # no float, `position: ABSOLUTE` and a `display: Flex` parent blockify.
  def test_blockification_reads_keywords_case_insensitively
    doc = Dommy.parse(<<~HTML).document
      <span id="a" style="float:NONE">a</span>
      <span id="b" style="position:ABSOLUTE">b</span>
      <div style="display:Flex"><span id="c">c</span></div>
      <span id="d" style="display:Inline;float:left">d</span>
    HTML
    display = ->(id) { Dommy::Internal::CSS::Cascade.computed_style(doc.get_element_by_id(id))["display"] }
    assert_equal %w[inline block block block], %w[a b c d].map(&display)
  end
end
