# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Element.closest().
# WPT: dom/nodes/Element-closest.html
# Spec: https://dom.spec.whatwg.org/#dom-element-closest
#
# closest(selector) walks the element itself and its ancestors,
# returning the first match (or nil). Implemented in
# lib/dommy/element.rb but lacked WPT-flavoured coverage.
class TestWPTElementClosest < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    # Build:  body > section.outer > div.middle > span#inner > em
    @section = @doc.create_element("section")
    @section.set_attribute("class", "outer")
    @div = @doc.create_element("div")
    @div.set_attribute("class", "middle")
    @span = @doc.create_element("span")
    @span.set_attribute("id", "inner")
    @em = @doc.create_element("em")
    @doc.body.append_child(@section)
    @section.append_child(@div)
    @div.append_child(@span)
    @span.append_child(@em)
  end

  def test_closest_returns_self_when_matching
    # Spec: the search starts at the element itself.
    assert_same(@span, @span.closest("span"))
  end

  def test_closest_returns_self_when_matching_id
    assert_same(@span, @span.closest("#inner"))
  end

  def test_closest_walks_up_to_immediate_parent
    assert_same(@div, @span.closest(".middle"))
  end

  def test_closest_walks_up_to_distant_ancestor
    assert_same(@section, @em.closest("section.outer"))
  end

  def test_closest_walks_up_to_body
    body = @doc.body
    assert_same(body, @em.closest("body"))
  end

  def test_closest_returns_nil_for_no_match
    assert_nil(@em.closest(".missing"))
  end

  def test_closest_returns_self_over_ancestor
    # When both the element and an ancestor match the selector,
    # closest returns the element itself (search begins at self).
    @div.set_attribute("data-tag", "yes")
    @span.set_attribute("data-tag", "yes")
    assert_same(@span, @span.closest("[data-tag]"))
  end

  def test_closest_with_compound_selector
    @div.set_attribute("data-role", "container")
    assert_same(@div, @em.closest("div.middle[data-role='container']"))
  end
end
