# frozen_string_literal: true

require_relative "../test_helper"

# The mutation invariant, completed for the three tree kinds that still had
# hand-rolled sequences: a Document's own child list, a ShadowRoot, and a
# `<template>`'s content fragment. Every one of them now runs the same shared
# WHATWG primitives — remove, insert, replace (remove BEFORE insert), replace
# all, string replace all — rather than leaning on the backend's implicit
# detach-on-add_child, which is a storage operation and not a DOM removal.
#
# Every expectation here was cross-checked against headless Chromium.
#
# Spec: https://dom.spec.whatwg.org/#mutation-algorithms
module MutationPrimitiveHelpers
  def records_for(*targets, subtree: false)
    seen = []
    targets.each do |target|
      observer = Dommy::MutationObserver.new(@win, proc { |recs| seen.concat(recs) })
      observer.__js_call__("observe", [target, {"childList" => true, "subtree" => subtree}])
    end
    yield
    @win.scheduler.drain_microtasks
    seen.map do |record|
      [record.__js_get__("target"),
       record.__js_get__("addedNodes").size,
       record.__js_get__("removedNodes").size]
    end
  end
end

# Moving an existing node under the Document itself is a removal from its old
# parent followed by an insertion — the backend would detach it silently on
# add_child, which skips the removing steps and the old parent's record.
# WPT: dom/nodes/Node-appendChild.html, dom/ranges/Range-mutations-appendChild.html
class TestWPTDocumentLevelMutation < Minitest::Test
  include DommyTestHelper
  include MutationPrimitiveHelpers

  def setup
    @win = make_window("<div id='c'></div>")
    @doc = @win.document
    @container = @doc.get_element_by_id("c")
  end

  # A comment is one of the few node types a Document accepts alongside the
  # document element, which makes it the usable probe for document-level moves.
  def comment_in_container(text = "x")
    comment = @doc.create_comment(text)
    @container.append_child(comment)
    comment
  end

  def test_moving_a_node_to_the_document_runs_the_old_parents_removing_steps
    comment = comment_in_container
    range = @doc.create_range
    range.set_start(@container, 1)
    range.set_end(@container, 1)
    @doc.append_child(comment)
    assert_same(@doc, comment.parent_node)
    assert_equal([0, 0], [range.start_offset, range.end_offset])
  end

  def test_moving_a_node_to_the_document_notifies_both_parents
    comment = comment_in_container
    seen = records_for(@container, @doc) { @doc.append_child(comment) }
    assert_equal([[@container, 0, 1], [@doc, 1, 0]], seen)
  end

  # An observer registered on the Document without `subtree` still watches the
  # document's OWN child list.
  def test_removing_a_document_child_notifies_the_document
    comment = comment_in_container
    @doc.append_child(comment)
    seen = records_for(@doc) { @doc.__js_call__("removeChild", [comment]) }
    assert_equal([[@doc, 0, 1]], seen)
  end

  def test_insertBefore_on_the_document_moves_through_the_same_path
    comment = comment_in_container
    range = @doc.create_range
    range.set_start(@container, 1)
    range.set_end(@container, 1)
    @doc.__js_call__("insertBefore", [comment, @doc.document_element])
    assert_same(@doc, comment.parent_node)
    assert_equal([0, 0], [range.start_offset, range.end_offset])
    # It landed before the document element, not appended at the end.
    children = @doc.child_nodes.to_a
    assert_same(comment, children[children.index(@doc.document_element) - 1])
  end

  # replaceChild adopts the incoming node — which removes it from its current
  # parent — BEFORE removing the child it replaces, so both parents are notified.
  def test_replaceChild_on_the_document_notifies_the_incoming_nodes_old_parent
    old_child = @doc.create_comment("old")
    @doc.append_child(old_child)
    incoming = comment_in_container("new")
    seen = records_for(@container, @doc) { @doc.__js_call__("replaceChild", [incoming, old_child]) }
    assert_equal([[@container, 0, 1], [@doc, 1, 1]], seen)
    assert_same(@doc, incoming.parent_node)
    assert_nil(old_child.parent_node)
  end

  def test_a_node_iterator_inside_a_subtree_moved_to_the_document_is_rewound
    @container.inner_html = "<a><x></x></a>"
    moved = @container.first_child
    iterator = @doc.create_node_iterator(@container)
    3.times { iterator.next_node }
    @doc.document_element.append_child(moved)
    assert_same(@container, iterator.__js_get__("referenceNode"))
    refute(iterator.__js_get__("pointerBeforeReferenceNode"))
  end
end

# A ShadowRoot is a DocumentFragment, so textContent= is WHATWG "string replace
# all" and replaceChild is the same remove-before-insert as everywhere else.
# WPT: dom/nodes/Node-textContent.html, dom/nodes/Node-replaceChild.html,
#      shadow-dom/ShadowRoot-interface.html
class TestWPTShadowRootReplaceSemantics < Minitest::Test
  include DommyTestHelper
  include MutationPrimitiveHelpers

  def setup
    @win = make_window("<div id='h'></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("h")
    @root = @host.attach_shadow(mode: "open")
    @root.inner_html = "<a></a><b></b>"
  end

  def test_textContent_assignment_leaves_a_single_text_node
    @root.text_content = "hello"
    assert_equal(1, @root.child_nodes.to_a.size)
    assert_kind_of(Dommy::TextNode, @root.first_child)
    assert_equal("hello", @root.text_content)
  end

  # "string replace all" only creates a Text node for a NON-empty string.
  def test_assigning_the_empty_string_leaves_no_children
    @root.text_content = ""
    assert_equal(0, @root.child_nodes.to_a.size)
    assert_nil(@root.first_child)
  end

  def test_textContent_assignment_queues_one_record_for_the_whole_swap
    seen = records_for(@root) { @root.text_content = "hello" }
    assert_equal([[@root, 1, 2]], seen)
  end

  def test_textContent_assignment_moves_a_boundary_at_a_child_offset
    range = @doc.create_range
    range.set_start(@root, 1)
    range.set_end(@root, 2)
    @root.text_content = "abc"
    assert_equal([0, 0], [range.start_offset, range.end_offset])
  end

  def test_textContent_assignment_moves_a_boundary_inside_a_removed_child
    range = @doc.create_range
    range.set_start(@root.first_child, 0)
    range.set_end(@root.first_child, 0)
    @root.text_content = "abc"
    assert_same(@root, range.start_container)
    assert_equal(0, range.start_offset)
  end

  def test_textContent_assignment_disconnects_a_custom_element
    klass = Class.new(Dommy::HTMLElement) do
      attr_accessor :disconnected_count
      define_method(:disconnected_callback) { @disconnected_count = (@disconnected_count || 0) + 1 }
    end
    @win.custom_elements.define("x-shadow-child", klass)
    @root.inner_html = "<x-shadow-child></x-shadow-child>"
    child = @root.first_child
    @root.text_content = "gone"
    assert_equal(1, child.disconnected_count)
  end

  # ---- replaceChild ----

  def test_replaceChild_removes_before_inserting
    old_child = @root.first_child
    old_child.append_child(@doc.create_element("x"))
    iterator = @doc.create_node_iterator(@root)
    3.times { iterator.next_node }
    @root.replace_child(@doc.create_element("z"), old_child)
    assert_same(@root, iterator.__js_get__("referenceNode"))
    assert_equal(%w[z b], @root.child_nodes.to_a.map(&:local_name))
  end

  def test_replaceChild_adjusts_live_range_boundaries
    old_child = @root.first_child
    old_child.append_child(@doc.create_element("x"))
    range = @doc.create_range
    range.set_start(old_child.first_child, 0)
    range.set_end(@root, 2)
    @root.replace_child(@doc.create_element("z"), old_child)
    assert_same(@root, range.start_container)
    assert_equal([0, 2], [range.start_offset, range.end_offset])
  end

  # The incoming node is already a child of this same shadow root: it has to be
  # removed from its own slot before landing in the replaced child's.
  def test_replaceChild_with_an_existing_sibling
    @root.inner_html = "<a></a><b></b><i></i>"
    first, second = @root.child_nodes.to_a
    @root.replace_child(second, first)
    assert_equal(%w[b i], @root.child_nodes.to_a.map(&:local_name))
  end

  def test_replaceChild_with_a_node_from_another_parent
    incoming = @doc.create_element("p")
    @host.append_child(incoming) # light DOM
    @root.replace_child(incoming, @root.first_child)
    assert_equal(%w[p b], @root.child_nodes.to_a.map(&:local_name))
    assert_same(@root, incoming.parent_node)
  end

  def test_replaceChild_with_a_fragment_inserts_its_children_in_order
    fragment = @doc.create_document_fragment
    fragment.append(@doc.create_element("p"), @doc.create_element("q"))
    seen = records_for(@root) { @root.replace_child(fragment, @root.first_child) }
    assert_equal(%w[p q b], @root.child_nodes.to_a.map(&:local_name))
    assert_equal([[@root, 2, 1]], seen)
  end
end

# HTML gives each <template> ONE associated DocumentFragment. innerHTML=
# retargets to that fragment and replaces all of its children, so the content
# object itself is never exchanged.
# WPT: html/semantics/scripting-1/the-template-element/innerhtml-on-templates/
# Spec: https://html.spec.whatwg.org/#dom-innerhtml
class TestWPTTemplateContentIdentity < Minitest::Test
  include DommyTestHelper
  include MutationPrimitiveHelpers

  def setup
    @win = make_window
    @doc = @win.document
    @template = @doc.create_element("template")
  end

  def test_content_identity_survives_innerHTML_assignment
    content = @template.content
    @template.inner_html = "<span>x</span>"
    assert_same(content, @template.content)
    assert_equal("span", @template.content.first_child.local_name)
  end

  # A reference taken once keeps tracking the template's current contents, and
  # the nodes it held before are genuinely detached.
  def test_a_held_content_reference_stays_live_across_assignments
    content = @template.content
    @template.inner_html = "<a></a>"
    first = content.first_child
    @template.inner_html = "<b></b>"
    assert_same(content, @template.content)
    assert_equal("b", content.first_child.local_name)
    assert_nil(first.parent_node)
  end

  def test_an_observer_on_the_content_sees_each_assignment
    content = @template.content
    seen = records_for(content) do
      @template.inner_html = "<span>x</span>"
      @template.inner_html = "<a></a>"
      @template.inner_html = "<b></b>"
    end
    assert_equal([[content, 1, 0], [content, 1, 1], [content, 1, 1]], seen)
  end

  def test_a_live_range_on_the_content_follows_the_replace_all
    @template.inner_html = "<a></a><b></b>"
    content = @template.content
    range = @doc.create_range
    range.set_start(content, 1)
    range.collapse(true)
    @template.inner_html = "<i></i>"
    assert_same(content, range.start_container)
    assert_equal(0, range.start_offset)
  end

  # A DocumentFragment is never connected, so a custom element parsed into a
  # template's content gets no connectedCallback until it is inserted into a
  # document — the replace-all on the content fragment must not fake one.
  def test_a_custom_element_in_template_content_is_not_connected_yet
    connected = 0
    klass = Class.new(Dommy::HTMLElement) do
      define_method(:connected_callback) { connected += 1 }
    end
    @win.custom_elements.define("x-tpl-child", klass)
    @template.inner_html = "<x-tpl-child></x-tpl-child>"
    assert_equal(0, connected)
    refute(@template.content.is_connected?)

    @doc.body.append_child(@template.content)
    assert_equal(1, connected)
  end

  def test_parsed_template_content_keeps_one_identity_too
    document = Dommy.parse("<template id='t'><p>parsed</p></template>").document
    template = document.get_element_by_id("t")
    content = template.content
    assert_equal("p", content.first_child.local_name)
    template.inner_html = "<em>replaced</em>"
    assert_same(content, template.content)
    assert_equal("em", content.first_child.local_name)
  end
end
