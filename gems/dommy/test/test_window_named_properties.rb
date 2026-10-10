# frozen_string_literal: true

require_relative "test_helper"

# HTML §7.2.2.3 "Named access on the Window object": the Window's supported
# property names are its child navigables' target names, the names of its
# document's embed / form / img / object elements and every element's id, in
# tree order; a name's value is the child's window, else the one element,
# else an HTMLCollection of them. (That they sit behind every member and JS
# global, unenumerable, is the bridge's: see the WPT
# html/browsers/the-window-object/named-access-on-the-window-object/ files.)
class TestWindowNamedProperties < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <div id="first"></div>
      <iframe name="frame1"></iframe>
      <form name="f"></form><img name="pic" id="picture"><span name="not-a-named-element"></span>
      <object name="o"></object><embed name="e">
      <p id="twice"></p><p id="twice"></p>
      <svg><rect id="shape"/></svg>
      <b id=""></b><a name="ignored"></a>
    HTML
    @doc = @win.document
  end

  def test_the_supported_names_in_tree_order
    assert_equal(%w[first frame1 f pic picture o e twice shape], @win.__js_named_props__)
  end

  def test_an_id_names_the_element
    assert_same(@doc.get_element_by_id("first"), @win.__js_named_get__("first"))
    assert_same(@doc.get_element_by_id("shape"), @win.__js_named_get__("shape"))
  end

  def test_a_child_navigable_name_is_its_window
    iframe = @doc.query_selector("iframe")
    assert_same(iframe.content_window, @win.__js_named_get__("frame1"))
    # The target name, not the attribute: renaming the child's window renames
    # the property.
    iframe.content_window.__js_set__("name", "renamed")
    assert_includes(@win.__js_named_props__, "renamed")
    refute_includes(@win.__js_named_props__, "frame1")
  end

  def test_only_embed_form_img_and_object_contribute_their_name
    assert_same(@doc.forms[0], @win.__js_named_get__("f"))
    assert_same(@doc.query_selector("img"), @win.__js_named_get__("pic"))
    refute_includes(@win.__js_named_props__, "not-a-named-element")
    refute_includes(@win.__js_named_props__, "ignored")
  end

  def test_several_elements_are_a_live_collection
    both = @win.__js_named_get__("twice")
    assert_kind_of(Dommy::HTMLCollection, both)
    assert_equal(2, both.length)
    @doc.query_selector("p").remove
    assert_equal(1, both.length)
    assert_same(@doc.query_selector("p"), @win.__js_named_get__("twice"))
  end

  # The names are read once per DOM change; any change of the tree, an id
  # or a name shows at the next lookup.
  def test_the_names_follow_every_change
    assert_equal(Dommy::Bridge::ABSENT, @win.__js_named_get__("late"))
    late = @doc.create_element("div")
    late.id = "late"
    @doc.body.append_child(late)
    assert_same(late, @win.__js_named_get__("late"))

    late.id = "renamed"
    assert_equal(Dommy::Bridge::ABSENT, @win.__js_named_get__("late"))
    assert_same(late, @win.__js_named_get__("renamed"))

    collection = @win.__js_named_get__("twice")
    @doc.get_element_by_id("twice").remove
    assert_equal(1, collection.length)
  end

  def test_an_unsupported_name_is_absent
    assert_equal(Dommy::Bridge::ABSENT, @win.__js_named_get__("missing"))
    assert_equal(Dommy::Bridge::ABSENT, @win.__js_named_get__(""))
    # Named properties are the bridge's last resort, not something __js_get__
    # answers in front of the window's members and globals.
    assert_equal(Dommy::Bridge::ABSENT, @win.__js_get__("first"))
  end
end
