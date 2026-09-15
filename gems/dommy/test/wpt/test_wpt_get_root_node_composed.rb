# frozen_string_literal: true

require_relative "../test_helper"

# getRootNode({composed: true}) returns the shadow-including root: a root that is
# a shadow root continues from its host. Element and ShadowRoot did that, but
# any other node inside a shadow tree — a Text, a Comment — returned the shadow
# root either way.
#
# Spec: https://dom.spec.whatwg.org/#dom-node-getrootnode
#       https://dom.spec.whatwg.org/#concept-shadow-including-root
class TestWPTGetRootNodeComposed < Minitest::Test
  include DommyTestHelper

  COMPOSED = { "composed" => true }.freeze

  def setup
    @win = make_window("<div id='host'></div>")
    @doc = @win.document
    @shadow = @doc.get_element_by_id("host").attach_shadow({ "mode" => "open" })
    @shadow.inner_html = "<span>in</span>tail<!--note-->"
  end

  def test_character_data_in_a_shadow_tree_reaches_the_document
    text_in_span = @shadow.first_child.first_child
    tail = @shadow.child_nodes.to_a[1]
    comment = @shadow.last_child

    [text_in_span, tail, comment].each do |node|
      assert_same(@shadow, node.get_root_node)
      assert_same(@doc, node.get_root_node(COMPOSED))
    end
  end

  def test_a_nested_shadow_tree_climbs_every_host
    inner_host = @shadow.first_child
    inner = inner_host.attach_shadow({ "mode" => "closed" })
    inner.inner_html = "deep"
    assert_same(inner, inner.first_child.get_root_node)
    assert_same(@doc, inner.first_child.get_root_node(COMPOSED))
  end

  def test_a_detached_node_is_its_own_root_either_way
    text = @doc.create_text_node("alone")
    assert_same(text, text.get_root_node(COMPOSED))
  end

  def test_over_the_bridge
    tail = @shadow.child_nodes.to_a[1]
    assert_same(@doc, tail.__js_call__("getRootNode", [COMPOSED]))
    assert_same(@shadow, tail.__js_call__("getRootNode", []))
  end
end
