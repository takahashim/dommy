# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

# HTML's innerText / outerText (HTML §3.2.7): the getter's rendered text
# collection, and the setter that turns line breaks into <br>. Cases mirror
# WPT html/dom/elements/the-innertext-and-outertext-properties.
class TestInnerTextGetter < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @container = @doc.create_element("div")
    @doc.body.append_child(@container)
  end

  def inner_text(html)
    @container.inner_html = html
    (@doc.get_element_by_id("target") || @container.first_element_child).inner_text
  end

  def test_white_space_normal
    assert_equal "abc", inner_text("<div> abc")
    assert_equal "abc", inner_text("<div>abc ")
    assert_equal "abc def", inner_text("<div>abc  def")
    assert_equal "abc def", inner_text("<div>abc\ndef")
    assert_equal "abc\ndef", inner_text("<div>abc <br>def")
    assert_equal "abc\ndef", inner_text("<div>abc<br> def")
  end

  def test_white_space_pre
    assert_equal " abc", inner_text("<pre> abc")
    assert_equal "abc  def", inner_text("<div style='white-space:pre'>abc  def")
    assert_equal "abc\ndef", inner_text("<pre>abc\ndef")
  end

  def test_white_space_pre_line
    assert_equal "abc def", inner_text("<div style='white-space:pre-line'>abc  def")
    assert_equal "abc\ndef", inner_text("<div style='white-space:pre-line'>abc\ndef")
  end

  def test_collapsing_across_element_boundaries
    assert_equal "abc def", inner_text("<div><span>abc </span> def")
    assert_equal "abc  def", inner_text("<div>abc <input> def")
    assert_equal "123abcdef", inner_text("<div>123<span style='display:inline-block'>abc</span>def")
  end

  def test_display_none_is_skipped
    assert_equal "abc", inner_text("<div style='display:none'>abc")
    assert_equal "abc  def", inner_text("<div style='display:none'>abc  def")
    assert_equal "123", inner_text("<div>123<span style='display:none'>abc")
  end

  def test_display_contents_runs_the_collection
    assert_equal "abc", inner_text("<div style='display:contents'>abc")
    assert_equal "", inner_text("<div style='display:contents'>   ")
  end

  def test_visibility_hidden_is_skipped
    assert_equal "", inner_text("<div style='visibility:hidden'>abc")
    assert_equal "123", inner_text("<div>123<span style='visibility:hidden'>abc")
  end

  def test_block_line_breaks
    assert_equal "123\nabc\ndef", inner_text("<div>123<div>abc</div>def")
    assert_equal "abc\ndef", inner_text("<div>abc<div></div>def")
    assert_equal "abc\ndef", inner_text("<div>abc<div></div><div></div>def")
  end

  def test_paragraph_double_breaks
    assert_equal "abc", inner_text("<div><p>abc")
    assert_equal "abc\n\ndef", inner_text("<div><p>abc<p>def")
    assert_equal "abc\n\ndef", inner_text("<div> abc<p>def</p> ")
    assert_equal "abc\n\n123\n\ndef", inner_text("<div><p>abc</p><div>123</div><p>def")
  end

  def test_text_transform
    assert_equal "ABC DEF", inner_text("<div style='text-transform:uppercase'>abc def")
    assert_equal "abc def", inner_text("<div style='text-transform:lowercase'>ABC DEF")
  end

  def test_tables
    assert_equal "a\tb", inner_text("<table><tr><td>a<td>b")
    assert_equal "abc\ndef", inner_text("<table><tr><td>abc<tr><td>def")
  end

  def test_select_options
    assert_equal "abc\ndef", inner_text("<select><option>abc</option><option>def")
    assert_equal "abc", inner_text("<select><option id='target'>abc</option><option>def")
    # Text and other elements directly in a <select> have no box, also when
    # innerText is asked of the <select> itself.
    assert_equal "abc\nx", inner_text("<select>junk<option>abc</option><optgroup><option>x</option></optgroup><div>d")
  end

  def test_replaced_element_contents_are_ignored
    assert_equal "", inner_text("<div><input type='text' value='abc'>")
    assert_equal "", inner_text("<div><textarea>abc")
    assert_equal "", inner_text("<div><img alt='abc'>")
  end

  def test_a_descendant_of_a_replaced_element_is_text_content
    # A child of <audio>/<canvas> is not rendered, so innerText is textContent.
    assert_equal "abc", inner_text("<div><canvas><span id='target'>abc</span></canvas>")
  end

  def test_closed_details_hides_non_summary_content
    assert_equal "abc", inner_text("<div><details><summary>abc</summary>123")
  end

  # With no CSS layer every computed property is unknown: visibility and
  # white-space take their initial values, and block boxes come from the tags.
  def test_without_a_css_layer
    unavailable = ->(*) { raise Dommy::Internal::CSS::Parser::Unavailable }
    Dommy::Internal::CSS::Cascade.stub(:computed_style, unavailable) do
      assert_equal "a b\nc", inner_text("<div>a  b<div>c")
    end
  end
end

class TestOuterText < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def test_inner_text_setter_replaces_children
    @doc.body.inner_html = "<div id='x'>old</div>"
    element = @doc.get_element_by_id("x")
    element.inner_text = "a\nb"
    assert_equal "a<br>b", element.inner_html
  end

  def test_inner_text_setter_empty_removes_children
    @doc.body.inner_html = "<div id='x'>old</div>"
    element = @doc.get_element_by_id("x")
    element.inner_text = ""
    assert_equal 0, element.child_nodes.length
  end

  def test_outer_text_setter_replaces_the_element
    @doc.body.inner_html = "<p>A <span id='x'>B</span> C</p>"
    @doc.get_element_by_id("x").outer_text = "Replaced"
    assert_equal "A Replaced C", @doc.body.text_content
  end

  def test_outer_text_setter_converts_breaks
    @doc.body.inner_html = "<p>A<span id='x'>B</span>C</p>"
    @doc.get_element_by_id("x").outer_text = "X\nY"
    assert_equal "<p>AX<br>YC</p>", @doc.body.inner_html
  end
end
