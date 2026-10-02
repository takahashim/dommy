# frozen_string_literal: true

require_relative "test_helper"

# removeAttribute, removeAttributeNS and removeAttributeNode all run the one
# "remove an attribute" (DOM §4.9): the Attr is detached, a record is queued,
# and an ARIA element reference the attribute reflected is dropped.
class TestAttributeRemoval < Minitest::Test
  def setup
    @win = Dommy.parse("<p id=p a=1></p><i id=t></i>")
    @doc = @win.document
    @p = @doc.get_element_by_id("p")
  end

  # removeAttributeNode removes that attribute, not the first with its
  # qualified name.
  def test_remove_attribute_node_removes_that_attribute
    @p.set_attribute_ns("urn:x", "a", "2")
    attr = @p.get_attribute_node_ns("urn:x", "a")

    assert_same attr, @p.remove_attribute_node(attr)
    assert_nil attr.owner_element
    assert_equal "2", attr.value
    assert_equal "1", @p.get_attribute_ns(nil, "a")
    assert_nil @p.get_attribute_ns("urn:x", "a")
  end

  def test_remove_attribute_node_queues_its_record
    @p.set_attribute_ns("urn:x", "a", "2")
    attr = @p.get_attribute_node_ns("urn:x", "a")
    observer = Dommy::MutationObserver.new(@win, proc {})
    observer.__js_call__("observe", [@p, {"attributes" => true, "attributeOldValue" => true}])

    @p.remove_attribute_node(attr)

    records = observer.__js_call__("takeRecords", [])
    assert_equal [%w[a urn:x 2]], records.map { |r| %w[attributeName attributeNamespace oldValue].map { |k| r.__js_get__(k) } }
  end

  # The explicit reference goes with the content attribute, whichever of the
  # three removes it.
  def test_removing_an_aria_attribute_drops_its_element_reference
    target = @doc.get_element_by_id("t")
    [
      -> { @p.remove_attribute("aria-activedescendant") },
      -> { @p.remove_attribute_ns(nil, "aria-activedescendant") },
      -> { @p.remove_attribute_node(@p.get_attribute_node("aria-activedescendant")) },
    ].each do |remove|
      @p.__js_set__("ariaActiveDescendantElement", target)
      assert_same target, @p.__js_get__("ariaActiveDescendantElement")

      remove.call

      assert_nil @p.__js_get__("ariaActiveDescendantElement")
    end
  end
end
