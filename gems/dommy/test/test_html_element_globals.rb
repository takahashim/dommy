# frozen_string_literal: true

require_relative "test_helper"

# The IDL attributes every HTML element has (HTMLElement and the mixins it
# includes): what each reads from its content attribute, and the default
# when there is none.
class TestHTMLElementGlobals < Minitest::Test
  include DommyTestHelper

  def setup
    @doc = make_window("<div id=host></div>").document
    @host = @doc.get_element_by_id("host")
  end

  def element(tag = "div", **attributes)
    el = @doc.create_element(tag)
    attributes.each { |name, value| el.set_attribute(name.to_s, value) }
    @host.append_child(el)
  end

  def test_plain_reflections
    el = element(accesskey: "k", autofocus: "", inert: "", headingreset: "", headingoffset: "3")
    assert_equal ["k", true, true, true, 3], %w[accessKey autofocus inert headingReset headingOffset].map { |k| el.__js_get__(k) }

    el.__js_set__("headingOffset", 20)
    assert_equal 8, el.__js_get__("headingOffset")
    plain = element
    assert_equal ["", false, false, false, 0], %w[accessKey autofocus inert headingReset headingOffset].map { |k| plain.__js_get__(k) }
  end

  # tabIndex reads the attribute as an integer, else 0 for the elements a
  # user can usually focus and -1 for the rest; SVG's `a` is one of them.
  def test_tab_index
    assert_equal [0, 0, -1, -1], [element("a"), element("button"), element, element("span")].map { |e| e.__js_get__("tabIndex") }
    details = element("details")
    first = details.append_child(@doc.create_element("summary"))
    second = details.append_child(@doc.create_element("summary"))
    assert_equal [0, -1], [first, second].map { |e| e.__js_get__("tabIndex") }
    assert_equal [5, -1], [element(tabindex: " 5x"), element(tabindex: "x")].map { |e| e.__js_get__("tabIndex") }

    svg = "http://www.w3.org/2000/svg"
    assert_equal [0, -1], [@doc.create_element_ns(svg, "a"), @doc.create_element_ns(svg, "g")].map { |e| e.__js_get__("tabIndex") }

    el = element
    el.__js_set__("tabIndex", 3)
    assert_equal ["3", 3], [el.get_attribute("tabindex"), el.__js_get__("tabIndex")]
  end
end
