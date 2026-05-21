# frozen_string_literal: true

require_relative "test_helper"

# Top-level entry points: `Dommy.parse(html)` and `Dommy.new_window`.
# Mirrors `happy-dom`'s `new Window()` + `document.write(html)` idiom.
class TestDommy < Minitest::Test
  def test_parse_returns_window_with_populated_body
    win = Dommy.parse("<div id='hi'>Hello</div>")
    assert_kind_of(Dommy::Window, win)
    refute_nil(win.document.get_element_by_id("hi"))
    assert_equal("Hello", win.document.get_element_by_id("hi").text_content)
  end

  def test_parse_empty_html_yields_empty_body
    win = Dommy.parse("")
    assert_equal("", win.document.body.inner_html.to_s.strip)
  end

  def test_new_window_blank_document
    win = Dommy.new_window
    assert_kind_of(Dommy::Document, win.document)
    assert_equal("BODY", win.document.body.tag_name)
  end

  def test_window_has_no_host_required
    # Standalone CRuby usage — host argument is optional.
    win = Dommy::Window.new
    assert_nil(win.instance_variable_get(:@host))
  end
end
