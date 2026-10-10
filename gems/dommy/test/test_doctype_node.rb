# frozen_string_literal: true

require_relative "test_helper"

# A DocumentType as a Document's child and as a Node: it can be replaced by
# the element that would follow it, removed like any child, and has only the
# members of Node and ChildNode. And a CharacterData node knows whether it is
# connected, as every Node does.
class TestDoctypeNode < Minitest::Test
  include DommyTestHelper

  def test_character_data_knows_whether_it_is_connected
    doc = make_window("<p>text</p>").document
    fragment = doc.create_document_fragment
    comment = doc.create_comment("c")
    fragment.append_child(comment)
    pi = doc.create_processing_instruction("pi", "x")
    fragment.append_child(pi)

    refute comment.is_connected?
    assert_equal false, pi.__js_get__("isConnected")
    assert doc.query_selector("p").first_child.is_connected?
    doc.body.append_child(fragment)
    assert comment.__js_get__("isConnected")
  end
end
