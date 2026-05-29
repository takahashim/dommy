# frozen_string_literal: true

require_relative "../test_helper"

class TestShadowRootRegistry < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
    # Real ShadowRoot creation registers via Document, so we test via that path too
    @shadow = @host.attach_shadow({"mode" => "open"})
    @shadow.inner_html = "<button id='btn'>X</button>"
    @btn_node = @shadow.get_element_by_id("btn").__node__
  end

  def test_find_for_fragment_returns_shadow_root
    fragment_node = @shadow.__node__
    registry = Dommy::Internal::ShadowRootRegistry.new
    registry.register(fragment_node, @shadow)
    assert_equal(@shadow, registry.find_for_fragment(fragment_node))
  end

  def test_find_for_fragment_returns_nil_for_unknown_fragment
    registry = Dommy::Internal::ShadowRootRegistry.new
    other = @doc.nokogiri_doc.fragment("")
    assert_nil(registry.find_for_fragment(other))
  end

  def test_find_for_fragment_returns_nil_for_nil
    registry = Dommy::Internal::ShadowRootRegistry.new
    assert_nil(registry.find_for_fragment(nil))
  end

  def test_find_enclosing_walks_ancestors
    # Document's registry already has the shadow registered
    result = @doc.internal_shadow_root_containing(@btn_node)
    assert_equal(@shadow, result)
  end

  def test_find_enclosing_returns_nil_outside_shadow_tree
    body_node = @doc.body.__node__
    result = @doc.internal_shadow_root_containing(body_node)
    assert_nil(result)
  end
end
