# frozen_string_literal: true

require_relative "../test_helper"

# "Queue a tree mutation record" takes previousSibling and nextSibling from the
# insertion point as the algorithm computed it, which is BEFORE anything moved:
# insert step 6 for an insertion, replace step 4 for a replacement. Reading the
# tree afterwards gives a different answer whenever the node being inserted was
# already a sibling of the insertion point.
#
# insertBefore and replaceChild / replaceWith read it too late, and a
# DocumentFragment's insertBefore queued no addition record at all.
#
# Spec: https://dom.spec.whatwg.org/#concept-node-insert
#       https://dom.spec.whatwg.org/#concept-node-replace
# Found by differential testing against a Lean 4 formalization of the standard.
class TestWPTMutationRecordInsertionPoint < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @observer = Dommy::MutationObserver.new(@win, proc { |_rs| nil })
  end

  def observe(target, options)
    @observer.__js_call__("observe", [target, options])
  end

  def taken
    @observer.__js_call__("takeRecords", [])
  end

  def nodes_of(record, key)
    record.__js_get__(key).to_a
  end

  # `parent.insertBefore(itsLastChild, null)` moves nothing, but the algorithm
  # still removes and re-appends. Insert step 6 reads the parent's last child
  # BEFORE the removal, so previousSibling is the node itself.
  def test_insert_before_null_reports_the_node_itself_as_previous_sibling
    parent = @doc.create_element("div")
    first = @doc.create_element("span")
    last = @doc.create_element("b")
    parent.append_child(first)
    parent.append_child(last)
    @doc.body.append_child(parent)
    observe(parent, { "childList" => true })

    parent.insert_before(last, nil)

    records = taken
    assert_equal 2, records.size
    removal, addition = records
    assert_equal [last], nodes_of(removal, "removedNodes")
    assert_equal [last], nodes_of(addition, "addedNodes")
    assert_equal last, addition.__js_get__("previousSibling")
    assert_nil addition.__js_get__("nextSibling")
  end

  # A DocumentFragment is a parent like any other: the insertion record is due.
  def test_fragment_insert_before_queues_the_addition_record
    frag = @doc.create_document_fragment
    el = @doc.create_element("div")
    frag.append_child(el)
    observe(frag, { "childList" => true })

    frag.insert_before(el, nil)

    records = taken
    assert_equal 2, records.size
    assert_equal [el], nodes_of(records[0], "removedNodes")
    assert_equal [el], nodes_of(records[1], "addedNodes")
    assert_equal el, records[1].__js_get__("previousSibling")
  end

  # Replacing a node with its own previous sibling: replace step 4 reads the old
  # child's previous sibling before step 6 adopts (and so removes) it.
  def test_replace_child_reads_previous_sibling_before_the_adopt
    parent = @doc.create_element("div")
    a = @doc.create_comment("a")
    b = @doc.create_text_node("b")
    c = @doc.create_text_node("c")
    [a, b, c].each { |n| parent.append_child(n) }
    @doc.body.append_child(parent)
    observe(parent, { "childList" => true })

    parent.replace_child(b, c)

    records = taken
    assert_equal 2, records.size
    addition = records[1]
    assert_equal [b], nodes_of(addition, "addedNodes")
    assert_equal [c], nodes_of(addition, "removedNodes")
    assert_equal b, addition.__js_get__("previousSibling")
    assert_nil addition.__js_get__("nextSibling")
  end

  # replaceWith goes through the same "replace" algorithm.
  def test_replace_with_reads_previous_sibling_before_the_adopt
    parent = @doc.create_element("div")
    a = @doc.create_comment("a")
    b = @doc.create_text_node("b")
    c = @doc.create_text_node("c")
    [a, b, c].each { |n| parent.append_child(n) }
    @doc.body.append_child(parent)
    observe(parent, { "childList" => true })

    c.replace_with(b)

    records = taken
    assert_equal 2, records.size
    addition = records[1]
    assert_equal [b], nodes_of(addition, "addedNodes")
    assert_equal [c], nodes_of(addition, "removedNodes")
    assert_equal b, addition.__js_get__("previousSibling")
  end

  # A document is a parent too, and its insertBefore reads the same point.
  def test_document_insert_before_reports_the_insertion_point
    doc = Dommy::DOMParser.new.parse_from_string("<root/>", "application/xml")
    comment = doc.create_comment("c")
    doc.append_child(comment)
    win = @win
    observer = Dommy::MutationObserver.new(win, proc { |_rs| nil })
    observer.__js_call__("observe", [doc, { "childList" => true }])

    doc.insert_before(comment, nil)

    records = observer.__js_call__("takeRecords", [])
    assert_equal 2, records.size
    assert_equal comment, records[1].__js_get__("previousSibling")
  end
end
