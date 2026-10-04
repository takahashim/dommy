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
end
