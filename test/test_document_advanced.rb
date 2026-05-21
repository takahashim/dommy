# frozen_string_literal: true

require_relative "test_helper"

# Cross-document transfer (importNode / adoptNode), legacy
# createEvent factory, and the layout-less stubs.
class TestDocumentAdvanced < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    # Build a second document to source nodes from.
    @other = Dommy::Window.new
    @other.document.body.inner_html = "<section id='s'><p>hi</p></section>"
    @src = @other.document.get_element_by_id("s")
  end

  # --- importNode ---

  def test_import_node_shallow_copies_element_without_children
    imported = @doc.import_node(@src, false)
    refute_nil(imported)
    assert_equal("SECTION", imported.tag_name)
    assert_equal("s", imported.id)
    assert_equal(0, imported.child_element_count)
  end

  def test_import_node_deep_copies_subtree
    imported = @doc.import_node(@src, true)
    assert_equal(1, imported.child_element_count)
    assert_equal("P", imported.children[0].tag_name)
    assert_equal("hi", imported.children[0].text_content)
  end

  def test_import_node_does_not_remove_source
    @doc.import_node(@src, true)
    refute_nil(@other.document.get_element_by_id("s"))
  end

  def test_import_node_attaches_to_this_document
    imported = @doc.import_node(@src, true)
    @doc.body.append(imported)
    refute_nil(@doc.get_element_by_id("s"))
  end

  # --- adoptNode ---

  def test_adopt_node_detaches_source
    adopted = @doc.adopt_node(@src)
    refute_nil(adopted)
    # Source is detached from its previous owner.
    assert_nil(@other.document.get_element_by_id("s"))
  end

  def test_adopt_node_can_be_appended_to_this_doc
    adopted = @doc.adopt_node(@src)
    @doc.body.append(adopted)
    refute_nil(@doc.get_element_by_id("s"))
  end

  # --- createEvent ---

  def test_create_event_returns_event
    ev = @doc.create_event("Event")
    assert_kind_of(Dommy::Event, ev)
  end

  def test_create_event_custom_event
    ev = @doc.create_event("CustomEvent")
    assert_kind_of(Dommy::CustomEvent, ev)
  end

  def test_create_event_mouse_event
    ev = @doc.create_event("MouseEvent")
    assert_kind_of(Dommy::MouseEvent, ev)
  end

  def test_create_event_keyboard_event
    ev = @doc.create_event("KeyboardEvent")
    assert_kind_of(Dommy::KeyboardEvent, ev)
  end

  def test_create_event_html_events_alias
    ev = @doc.create_event("HTMLEvents")
    assert_kind_of(Dommy::Event, ev)
  end

  def test_init_event_after_create_event
    ev = @doc.create_event("Event")
    ev.__js_call__("initEvent", ["test", true, true])
    assert_equal("test", ev.__js_get__("type"))
    assert_equal(true, ev.__js_get__("bubbles"))
    assert_equal(true, ev.__js_get__("cancelable"))
  end

  # --- layout-less stubs ---

  def test_has_focus_returns_true
    assert_equal(true, @doc.has_focus?)
  end

  def test_get_selection_returns_nil
    assert_nil(@doc.get_selection)
  end

  def test_element_from_point_returns_nil
    assert_nil(@doc.element_from_point(0, 0))
  end

  def test_query_command_supported_returns_false
    refute(@doc.query_command_supported("bold"))
    refute(@doc.query_command_supported("anything"))
  end

  # --- js_call routing ---

  def test_js_call_importNode
    imported = @doc.__js_call__("importNode", [@src, true])
    refute_nil(imported)
  end

  def test_js_call_createEvent
    ev = @doc.__js_call__("createEvent", ["Event"])
    assert_kind_of(Dommy::Event, ev)
  end
end
