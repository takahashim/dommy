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

  # A float, an absolutely positioned box and a flex item compute an
  # inline-level display to its block-level form.
  def test_blockification_of_the_computed_display
    doc = Dommy.parse(%(<div style="display:flex"><span id="a">x</span></div><span id="b" style="float:left">y</span><span id="c" style="position:absolute;display:inline-flex">z</span>)).document
    display = ->(id) { Dommy::Internal::CSS::Cascade.computed_style(doc.get_element_by_id(id))["display"] }
    assert_equal %w[block block flex], %w[a b c].map(&display)
  end
end
