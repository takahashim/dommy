# frozen_string_literal: true

require_relative "../test_helper"

# normalize() is a Node method, so every node has it. On a Document it merges
# the Text runs anywhere in the tree; on a node with no descendants it has
# nothing to do. Only Element and DocumentFragment carried it: Document and the
# leaf nodes raised NoMethodError from Ruby, and over the JS bridge a Document or
# ShadowRoot receiver silently merged nothing.
#
# Spec: https://dom.spec.whatwg.org/#dom-node-normalize
# Found by differential testing against a Lean 4 formalization of the standard
# (its fixed scenarios normalize-on-document and normalize-on-text-is-noop).
class TestWPTNodeNormalizeOnEveryNode < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<p id='p'></p><div id='host'></div>")
    @doc = @win.document
    @p = @doc.get_element_by_id("p")
  end

  def split_text_into(parent)
    parent.append_child(@doc.create_text_node("a"))
    parent.append_child(@doc.create_text_node(""))
    parent.append_child(@doc.create_text_node("b"))
  end

  def data_of(parent)
    parent.child_nodes.to_a.map(&:data)
  end

  def test_document_normalize_merges_text_runs_anywhere_in_the_tree
    split_text_into(@p)
    @doc.normalize
    assert_equal(["ab"], data_of(@p))
  end

  def test_document_normalize_over_the_bridge
    split_text_into(@p)
    @doc.__js_call__("normalize", [])
    assert_equal(["ab"], data_of(@p))
  end

  def test_shadow_root_normalize_over_the_bridge
    shadow = @doc.get_element_by_id("host").attach_shadow({ "mode" => "open" })
    split_text_into(shadow)
    shadow.__js_call__("normalize", [])
    assert_equal(["ab"], data_of(shadow))
  end

  def test_a_node_without_descendants_has_nothing_to_normalize
    text = @doc.create_text_node("a")
    comment = @doc.create_comment("c")
    @p.append_child(text)
    @p.append_child(comment)

    assert_nil(text.normalize)
    assert_nil(comment.normalize)
    assert_nil(text.__js_call__("normalize", []))
    assert_equal(["a", "c"], data_of(@p))
  end
end
