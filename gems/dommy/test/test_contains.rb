# frozen_string_literal: true

require_relative "test_helper"

class TestContainsConnected < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='outer'><p><span id='inner'>x</span></p></div>")
    @doc = @win.document
    @outer = @doc.get_element_by_id("outer")
    @inner = @doc.get_element_by_id("inner")
  end

  def test_contains_self
    assert(@outer.contains?(@outer))
  end

  def test_contains_descendant
    assert(@outer.contains?(@inner))
  end

  def test_does_not_contain_ancestor
    refute(@inner.contains?(@outer))
  end

  def test_does_not_contain_unrelated
    other = @doc.create_element("div")
    refute(@outer.contains?(other))
  end

  def test_root_node_returns_document
    root = @inner.root_node
    refute_nil(root)
  end

  def test_is_connected_for_attached_element
    assert_equal(true, @inner.__js_get__("isConnected"))
  end

  def test_is_connected_false_for_detached
    el = @doc.create_element("div")
    assert_equal(false, el.__js_get__("isConnected"))
  end

  def test_toggle_attribute_adds
    el = @doc.create_element("input")
    assert_equal(true, el.toggle_attribute("disabled"))
    assert(el.has_attribute?("disabled"))
  end

  def test_toggle_attribute_removes
    el = @doc.create_element("input")
    el.set_attribute("disabled", "")
    assert_equal(false, el.toggle_attribute("disabled"))
    refute(el.has_attribute?("disabled"))
  end

  def test_toggle_attribute_force_true
    el = @doc.create_element("input")
    el.toggle_attribute("disabled", true)
    assert(el.has_attribute?("disabled"))
    el.toggle_attribute("disabled", true)
    assert(el.has_attribute?("disabled"))
  end

  def test_toggle_attribute_force_false
    el = @doc.create_element("input")
    el.set_attribute("disabled", "")
    el.toggle_attribute("disabled", false)
    refute(el.has_attribute?("disabled"))
  end
end
