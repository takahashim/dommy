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
end
