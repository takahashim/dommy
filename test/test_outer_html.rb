# frozen_string_literal: true

require_relative "test_helper"

class TestOuterHTML < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='root'><p id='target'>Hello</p></div>")
    @doc = @win.document
  end

  def test_outer_html_get
    p = @doc.get_element_by_id("target")
    assert_match(/<p[^>]*id=.target.[^>]*>Hello<\/p>/, p.outer_html)
  end

  def test_outer_html_set_replaces_element
    p = @doc.get_element_by_id("target")
    p.outer_html = "<span id='replaced'>Hi</span>"
    refute(@doc.get_element_by_id("target"))
    assert_equal("Hi", @doc.get_element_by_id("replaced").text_content)
  end

  def test_outer_html_set_multiple_elements
    p = @doc.get_element_by_id("target")
    p.outer_html = "<a>x</a><b>y</b>"
    root = @doc.get_element_by_id("root")
    assert_equal(2, root.child_element_count)
  end
end
