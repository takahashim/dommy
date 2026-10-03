# frozen_string_literal: true

require_relative "test_helper"

# A memoized querySelector(All) result is retired by Makiri's own count of
# child-list and attribute edits as well as by the document's generation, so
# an edit that reached the backend without passing through the document's
# mutation paths does not leave a stale answer behind.
class TestQueryCacheVersions < Minitest::Test
  def setup
    @doc = Dommy.parse("<ul><li id=a class=x>a</li><li id=b>b</li></ul>").document
  end

  def test_an_attribute_edited_behind_the_document_retires_the_result
    assert_equal ["a"], @doc.query_selector_all("li.x").map(&:id)
    @doc.get_element_by_id("b").__dommy_backend_node__["class"] = "x"
    assert_equal %w[a b], @doc.query_selector_all("li.x").map(&:id)
  end

  def test_a_child_added_behind_the_document_retires_the_result
    assert_equal 2, @doc.query_selector_all("li").length
    ul = @doc.query_selector("ul").__dommy_backend_node__
    ul.add_child(ul.document.create_element("li"))
    assert_equal 3, @doc.query_selector_all("li").length
  end

  # A text edit that flips nothing moves no epoch, by either count.
  def test_a_text_edit_that_flips_nothing_moves_no_epoch
    before = [@doc.dom_generation, @doc.style_generation, @doc.tree_generation]
    @doc.get_element_by_id("a").first_child.data = "aa"
    assert_equal before, [@doc.dom_generation, @doc.style_generation, @doc.tree_generation]
  end
end

