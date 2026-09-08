# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for the event path the dispatch algorithm builds: how it
# routes through slots, what composedPath() shows on either side of a closed
# shadow boundary, and how relatedTarget is retargeted.
#
# WPT: shadow-dom/event-composed-path.html,
#      shadow-dom/event-inside-slotted-node.html,
#      shadow-dom/event-with-related-target.html,
#      shadow-dom/event-post-dispatch.html,
#      dom/events/EventTarget-dispatchEvent.html
class TestWPTEventPathBase < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def label(node)
    return "nil" if node.nil?
    return node.class.name.split("::").last unless node.respond_to?(:tag_name)

    node.get_attribute("id") || node.tag_name
  end

  # Attach a listener to each [node, label] pair, dispatch, and return the
  # labels of the nodes whose listeners ran, in order.
  def visited(event, pairs)
    seen = []
    pairs.each { |node, name| node.add_event_listener(event.type) { seen << name } }
    pairs.first.first.dispatch_event(event)
    seen
  end
end

class TestWPTEventPathThroughSlots < TestWPTEventPathBase
  def setup
    super
    @host = @doc.create_element("x-host")
    @host.inner_html = "<p id='light'><b id='deep'></b></p>"
    @doc.body.append_child(@host)
    @root = @host.attach_shadow(mode: "open")
    @root.inner_html = "<div id='slotparent'><slot id='theslot'></slot></div>"
    @deep = @host.query_selector("#deep")
  end

  # A slotted node composes into its slot, so the path follows the *flattened*
  # tree: light DOM, then the slot and its shadow-tree ancestors, then the host.
  def test_path_routes_through_the_assigned_slot
    seen = visited(
      Dommy::Event.new("q", "bubbles" => true, "composed" => true),
      [[@deep, "deep"], [@host.query_selector("#light"), "light"],
       [@root.query_selector("#theslot"), "slot"], [@root.query_selector("#slotparent"), "slotparent"],
       [@root, "root"], [@host, "host"], [@doc.body, "body"]]
    )
    assert_equal(%w[deep light slot slotparent root host body], seen)
  end

  def test_composed_path_includes_the_slot
    path = nil
    @doc.body.add_event_listener("q") { |e| path = e.__js_call__("composedPath", []).map { |n| label(n) } }
    @deep.dispatch_event(Dommy::Event.new("q", "bubbles" => true, "composed" => true))
    assert_equal(%w[deep light theslot slotparent ShadowRoot X-HOST BODY], path.first(7))
  end

  def test_a_slotted_node_is_not_retargeted
    # The slotted node lives in the host's light DOM, so it is not encapsulated
    # and every listener sees it as the target.
    seen = {}
    [[@deep, "deep"], [@host, "host"], [@doc.body, "body"]].each do |node, name|
      node.add_event_listener("q") { |e| seen[name] = label(e.__js_get__("target")) }
    end
    @deep.dispatch_event(Dommy::Event.new("q", "bubbles" => true, "composed" => true))
    assert_equal({"deep" => "deep", "host" => "deep", "body" => "deep"}, seen)
  end
end

class TestWPTComposedPathClosedTrees < TestWPTEventPathBase
  def build(mode)
    host = @doc.create_element("x-#{mode}")
    @doc.body.append_child(host)
    root = host.attach_shadow(mode: mode)
    root.inner_html = "<i id='inside'></i>"
    [host, root, root.query_selector("#inside")]
  end

  def paths_for(mode)
    host, root, inside = build(mode)
    paths = {}
    [[inside, "inside"], [root, "root"], [host, "host"], [@doc.body, "body"]].each do |node, name|
      node.add_event_listener("r") { |e| paths[name] = e.__js_call__("composedPath", []).map { |n| label(n) } }
    end
    inside.dispatch_event(Dommy::Event.new("r", "bubbles" => true, "composed" => true))
    paths
  end

  def test_a_closed_tree_is_hidden_from_listeners_outside_it
    paths = paths_for("closed")
    refute_includes(paths["host"], "inside")
    refute_includes(paths["body"], "inside")
    assert_equal("X-CLOSED", paths["body"].first)
  end

  def test_a_closed_tree_is_visible_from_inside_it
    paths = paths_for("closed")
    assert_equal("inside", paths["inside"].first)
    assert_includes(paths["inside"], "ShadowRoot")
  end

  def test_an_open_tree_is_visible_from_outside
    paths = paths_for("open")
    assert_equal("inside", paths["body"].first)
    assert_includes(paths["body"], "ShadowRoot")
  end

  def test_composed_path_is_empty_after_dispatch
    _host, _root, inside = build("open")
    event = Dommy::Event.new("r", "bubbles" => true, "composed" => true)
    inside.dispatch_event(event)
    assert_empty(event.__js_call__("composedPath", []))
  end

  def test_an_uncomposed_event_does_not_leave_the_tree
    _host, root, inside = build("open")
    path = nil
    inside.add_event_listener("r") { |e| path = e.__js_call__("composedPath", []).map { |n| label(n) } }
    inside.dispatch_event(Dommy::Event.new("r", "bubbles" => true))
    assert_equal(%w[inside ShadowRoot], path)
    assert_same(root, inside.root_node)
  end
end

class TestWPTRelatedTargetRetargeting < TestWPTEventPathBase
  def setup
    super
    @host = @doc.create_element("x-h")
    @doc.body.append_child(@host)
    @root = @host.attach_shadow(mode: "open")
    @root.inner_html = "<a id='a'></a><b id='b'></b>"
    @a = @root.query_selector("#a")
    @b = @root.query_selector("#b")
  end

  def test_related_target_is_visible_inside_the_shadow_tree
    seen = {}
    [[@a, "a"], [@root, "root"]].each do |node, name|
      node.add_event_listener("mouseover") { |e| seen[name] = label(e.__js_get__("relatedTarget")) }
    end
    @a.dispatch_event(mouse_event)
    assert_equal({"a" => "b", "root" => "b"}, seen)
  end

  # Both nodes retarget onto the host, so from outside the tree the pointer never
  # moved: the event does not propagate past the shadow boundary at all.
  def test_a_move_within_one_shadow_tree_is_not_observable_outside
    fired = 0
    [@host, @doc.body].each { |node| node.add_event_listener("mouseover") { fired += 1 } }
    @a.dispatch_event(mouse_event)
    assert_equal(0, fired)
  end

  def test_related_target_in_the_light_dom_is_untouched
    x = @doc.create_element("x")
    y = @doc.create_element("y")
    @doc.body.append_child(x)
    @doc.body.append_child(y)
    seen = {}
    [[x, "x"], [@doc.body, "body"]].each do |node, name|
      node.add_event_listener("mouseout") { |e| seen[name] = label(e.__js_get__("relatedTarget")) }
    end
    x.dispatch_event(Dommy::MouseEvent.new("mouseout", "bubbles" => true, "relatedTarget" => y))
    assert_equal({"x" => "Y", "body" => "Y"}, seen)
  end

  def test_targets_are_cleared_after_a_dispatch_that_stayed_in_the_tree
    event = mouse_event
    @a.dispatch_event(event)
    assert_nil(event.__js_get__("target"))
    assert_nil(event.__js_get__("relatedTarget"))
  end

  private

  def mouse_event
    Dommy::MouseEvent.new("mouseover", "bubbles" => true, "composed" => true, "relatedTarget" => @b)
  end
end

class TestWPTDetachedDispatch < TestWPTEventPathBase
  # A detached node has no parent, so the path stops inside the detached
  # subtree instead of reaching the document.
  def test_a_detached_subtree_does_not_reach_the_document
    outer = @doc.create_element("div")
    inner = @doc.create_element("span")
    outer.append_child(inner)
    seen = []
    [[inner, "inner"], [outer, "outer"], [@doc, "document"], [@win, "window"]].each do |node, name|
      node.add_event_listener("t") { seen << name }
    end
    inner.dispatch_event(Dommy::Event.new("t", "bubbles" => true))
    assert_equal(%w[inner outer], seen)
  end

  def test_a_detached_composed_path_stops_at_the_subtree_root
    outer = @doc.create_element("div")
    inner = @doc.create_element("span")
    outer.append_child(inner)
    path = nil
    inner.add_event_listener("t") { |e| path = e.__js_call__("composedPath", []) }
    inner.dispatch_event(Dommy::Event.new("t", "bubbles" => true))
    assert_equal([inner, outer], path)
  end
end

class TestWPTDispatchEventValidation < TestWPTEventPathBase
  def setup
    super
    @node = @doc.create_element("div")
    @doc.body.append_child(@node)
  end

  def test_dispatching_null_is_a_type_error
    # Bridge::TypeError is the spec-mandated one the host maps to a JS TypeError.
    assert_raises(Dommy::Bridge::TypeError) { @node.dispatch_event(nil) }
  end

  def test_dispatching_a_non_event_is_a_type_error
    assert_raises(Dommy::Bridge::TypeError) { @node.dispatch_event("not-an-event") }
  end

  def test_dispatching_an_uninitialized_event_is_an_invalid_state_error
    event = @doc.create_event("Event")
    assert_raises(Dommy::DOMException::InvalidStateError) { @node.dispatch_event(event) }
  end

  def test_an_initialized_event_dispatches
    event = @doc.create_event("Event")
    event.__js_call__("initEvent", ["ready", true, false])
    fired = 0
    @node.add_event_listener("ready") { fired += 1 }
    assert_equal(true, @node.dispatch_event(event))
    assert_equal(1, fired)
  end

  def test_a_constructed_event_is_already_initialized
    fired = 0
    @node.add_event_listener("ready") { fired += 1 }
    @node.dispatch_event(Dommy::Event.new("ready"))
    assert_equal(1, fired)
  end
end
