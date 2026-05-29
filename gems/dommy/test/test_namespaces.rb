# frozen_string_literal: true

require_relative "test_helper"

class TestNamespacesAndFocus < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='x'></div>")
    @doc = @win.document
    @el = @doc.get_element_by_id("x")
  end

  def test_namespace_uri_for_html_element
    # Default HTML elements have the xhtml namespace per spec.
    uri = @el.namespace_uri
    assert_equal("http://www.w3.org/1999/xhtml", uri)
  end

  def test_local_name_lowercased
    assert_equal("div", @el.local_name)
  end

  def test_node_name_uppercased
    assert_equal("DIV", @el[:nodeName])
  end

  def test_slot_reflected
    @el.slot = "primary"
    assert_equal("primary", @el.slot)
    assert_equal("primary", @el.get_attribute("slot"))
  end

  def test_role_reflected
    @el.role = "button"
    assert_equal("button", @el.role)
    assert_equal("button", @el.get_attribute("role"))
  end

  def test_base_uri_returns_location_href
    assert_match(/^http:\/\/localhost\//, @el.base_uri)
  end

  def test_focus_updates_active_element
    @el.focus
    assert_same(@el, @doc.active_element)
  end

  def test_blur_resets_active_element_to_body
    @el.focus
    @el.blur
    assert_same(@doc.body, @doc.active_element)
  end

  def test_active_element_default_is_body
    assert_same(@doc.body, @doc.active_element)
  end
end
