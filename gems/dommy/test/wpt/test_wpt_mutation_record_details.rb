# frozen_string_literal: true

require_relative "../test_helper"

# WHATWG "queue a mutation record" walks the mutation target's INCLUSIVE
# ANCESTORS looking for registrations, and "queue a tree mutation record" fills
# in previousSibling / nextSibling from the insertion point as the algorithm
# computed it — before anything moved. takeRecords() drains the queue and
# nothing else.
#
# Spec: https://dom.spec.whatwg.org/#queueing-a-mutation-record
# Found by differential testing against a Lean 4 formalization of the standard.
class TestWPTMutationRecordDetails < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @records = []
    @observer = Dommy::MutationObserver.new(@win, proc { |rs| @records.concat(rs) })
  end

  def observe(target, options)
    @observer.__js_call__("observe", [target, options])
  end

  def taken
    @observer.__js_call__("takeRecords", [])
  end

  # A document observer with subtree sees its own tree, not every node that
  # happens to share the document as an owner: WHATWG reaches a registration
  # only through the target's inclusive ancestors.
  def test_a_document_subtree_observer_ignores_a_detached_node
    detached = @doc.create_comment("cc")
    observe(@doc, { "subtree" => true, "characterData" => true })

    detached.data = "dd"

    assert_empty taken
  end

  def test_a_document_subtree_observer_sees_a_node_in_its_tree
    attached = @doc.create_comment("cc")
    @doc.body.append_child(attached)
    observe(@doc, { "subtree" => true, "characterData" => true })

    attached.data = "dd"

    assert_equal 1, taken.size
  end

  # An observer registered on a DocumentFragment is a parent observer like any
  # other: removing one of its children queues a childList record on it.
  def test_removing_a_fragment_child_queues_a_record
    frag = @doc.create_document_fragment
    child = @doc.create_comment("cc")
    frag.append_child(child)
    observe(frag, { "childList" => true })

    frag.remove_child(child)

    records = taken

    assert_equal 1, records.size
    assert_equal frag, records[0].__js_get__("target")
    assert_equal [child], records[0].__js_get__("removedNodes").to_a
  end

  # Insert step 9's record carries step 6's previousSibling, which is measured
  # BEFORE step 7's adopt removes the node. Appending a node that is already the
  # last child therefore reports itself as the previous sibling.
  def test_append_child_of_the_last_child_reports_itself_as_previous_sibling
    a = @doc.create_element("i")
    b = @doc.create_element("b")
    parent = @doc.create_element("div")
    @doc.body.append_child(parent)
    parent.append_child(a)
    parent.append_child(b)
    observe(parent, { "childList" => true })

    parent.append_child(b)

    records = taken

    assert_equal 2, records.size
    assert_equal [b], records[0].__js_get__("removedNodes").to_a
    assert_equal a, records[0].__js_get__("previousSibling")
    assert_equal [b], records[1].__js_get__("addedNodes").to_a
    assert_equal b, records[1].__js_get__("previousSibling")
  end

  # `before` / `after` fill the record's siblings in too.
  def test_after_reports_the_insertion_point
    a = @doc.create_element("i")
    b = @doc.create_element("b")
    parent = @doc.create_element("div")
    @doc.body.append_child(parent)
    parent.append_child(a)
    parent.append_child(b)
    observe(parent, { "childList" => true })

    a.after(@doc.create_element("u"))

    records = taken

    assert_equal 1, records.size
    assert_equal a, records[0].__js_get__("previousSibling")
    assert_equal b, records[0].__js_get__("nextSibling")
  end

  # takeRecords() empties the record queue and nothing else. The transient
  # registered observers a removal installed live until the microtask
  # checkpoint, so a subtree observer keeps seeing the removed subtree.
  def test_take_records_does_not_end_transient_observation
    parent = @doc.create_element("div")
    child = @doc.create_element("span")
    parent.append_child(child)
    @doc.body.append_child(parent)
    observe(@doc.body, { "childList" => true, "subtree" => true })

    parent.remove
    taken # drains the removal record, keeps the transient registration

    child.append_child(@doc.create_element("i"))

    records = taken

    assert_equal 1, records.size
    assert_equal child, records[0].__js_get__("target")
  end

  # …and the microtask checkpoint does end it.
  def test_the_microtask_checkpoint_ends_transient_observation
    parent = @doc.create_element("div")
    child = @doc.create_element("span")
    parent.append_child(child)
    @doc.body.append_child(parent)
    observe(@doc.body, { "childList" => true, "subtree" => true })

    parent.remove
    @win.scheduler.drain_microtasks
    @records.clear

    child.append_child(@doc.create_element("i"))

    assert_empty taken
  end
end
