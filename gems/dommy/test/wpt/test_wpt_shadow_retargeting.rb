# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for event retargeting across a shadow boundary.
#
# WPT: shadow-dom/event-inside-shadow-tree.html,
#      shadow-dom/event-composed-path.html,
#      shadow-dom/event-inside-slotted-node.html
class TestWPTShadowEventRetargeting < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def name_of(node)
    node.respond_to?(:tag_name) ? node.tag_name : node.class.name.split("::").last
  end

  # Record the `target` each listed listener sees, keyed by label.
  def targets_for(event, pairs)
    seen = {}
    pairs.each do |node, label|
      node.add_event_listener(event.type) { |e| seen[label] = name_of(e.__js_get__("target")) }
    end
    pairs.first.first.dispatch_event(event)
    seen
  end

  def build_host
    host = @doc.create_element("my-card")
    @doc.body.append_child(host)
    root = host.attach_shadow(mode: "open")
    root.inner_html = "<div id='inner'><span id='deep'></span></div>"
    [host, root, root.query_selector("#deep")]
  end

  def test_listeners_inside_the_shadow_tree_see_the_real_target
    _host, root, deep = build_host
    seen = targets_for(
      Dommy::Event.new("q", "bubbles" => true, "composed" => true),
      [[deep, "deep"], [root.query_selector("#inner"), "inner"], [root, "root"]]
    )
    assert_equal({"deep" => "SPAN", "inner" => "SPAN", "root" => "SPAN"}, seen)
  end

  def test_listeners_outside_the_shadow_tree_see_the_host
    host, _root, deep = build_host
    seen = targets_for(
      Dommy::Event.new("q", "bubbles" => true, "composed" => true),
      [[deep, "deep"], [host, "host"], [@doc.body, "body"], [@doc, "document"], [@win, "window"]]
    )
    assert_equal("SPAN", seen["deep"])
    assert_equal(%w[MY-CARD MY-CARD MY-CARD MY-CARD], seen.values_at("host", "body", "document", "window"))
  end

  def test_current_target_is_still_the_node_the_listener_is_on
    host, _root, deep = build_host
    seen = []
    [host, @doc.body].each do |node|
      node.add_event_listener("u") { |e| seen << name_of(e.__js_get__("currentTarget")) }
    end
    deep.dispatch_event(Dommy::Event.new("u", "bubbles" => true, "composed" => true))
    assert_equal(%w[MY-CARD BODY], seen)
  end

  def test_a_non_composed_event_never_leaves_the_shadow_tree
    host, root, deep = build_host
    seen = targets_for(
      Dommy::Event.new("r", "bubbles" => true),
      [[deep, "deep"], [root, "root"], [host, "host"], [@doc.body, "body"]]
    )
    assert_equal({"deep" => "SPAN", "root" => "SPAN"}, seen)
  end

  def test_a_light_dom_event_is_not_retargeted
    outer = @doc.create_element("a")
    inner = @doc.create_element("b")
    outer.append_child(inner)
    @doc.body.append_child(outer)
    seen = targets_for(
      Dommy::Event.new("s", "bubbles" => true),
      [[inner, "inner"], [outer, "outer"], [@doc.body, "body"]]
    )
    assert_equal({"inner" => "B", "outer" => "B", "body" => "B"}, seen)
  end

  def test_nested_shadow_trees_retarget_one_boundary_at_a_time
    outer_host = @doc.create_element("x-outer")
    @doc.body.append_child(outer_host)
    outer_root = outer_host.attach_shadow(mode: "open")
    mid_host = @doc.create_element("x-inner")
    outer_root.append_child(mid_host)
    inner_root = mid_host.attach_shadow(mode: "open")
    leaf = @doc.create_element("i")
    inner_root.append_child(leaf)

    seen = targets_for(
      Dommy::Event.new("t", "bubbles" => true, "composed" => true),
      [[leaf, "leaf"], [inner_root, "inner_root"], [mid_host, "mid_host"],
       [outer_root, "outer_root"], [outer_host, "outer_host"], [@doc.body, "body"]]
    )
    assert_equal(
      {"leaf" => "I", "inner_root" => "I", "mid_host" => "X-INNER",
       "outer_root" => "X-INNER", "outer_host" => "X-OUTER", "body" => "X-OUTER"},
      seen
    )
  end

  def test_a_slotted_light_dom_node_is_not_retargeted
    # The slotted node lives in the host's light DOM, so it is not encapsulated
    # by the shadow tree and every listener sees it as the target.
    host = @doc.create_element("x-slot")
    host.inner_html = "<p id='light'></p>"
    @doc.body.append_child(host)
    root = host.attach_shadow(mode: "open")
    root.inner_html = "<slot></slot>"

    seen = targets_for(
      Dommy::Event.new("v", "bubbles" => true, "composed" => true),
      [[host.query_selector("#light"), "light"], [host, "host"], [@doc.body, "body"]]
    )
    assert_equal({"light" => "P", "host" => "P", "body" => "P"}, seen)
  end

  def test_parent_node_from_the_top_of_a_shadow_tree_is_the_shadow_root
    _host, root, deep = build_host
    inner = root.query_selector("#inner")
    assert_same(root, inner.parent_node)
    assert_nil(inner.parent_element)
    assert_same(root, deep.root_node)
  end

  def test_a_plain_fragment_is_not_a_shadow_root
    assert_instance_of(Dommy::Fragment, @doc.create_document_fragment)
    template = @doc.create_element("template")
    template.inner_html = "<p></p>"
    assert_instance_of(Dommy::Fragment, template.content)
  end

  # Dispatch step 18: an event that never left the shadow tree must not leave an
  # encapsulated node reachable through `target` afterwards.
  def test_target_is_cleared_after_an_uncomposed_shadow_dispatch
    _host, _root, deep = build_host
    event = Dommy::Event.new("y", "bubbles" => true)
    deep.dispatch_event(event)
    assert_nil(event.__js_get__("target"))
  end

  def test_target_survives_a_composed_shadow_dispatch_as_the_host
    host, _root, deep = build_host
    event = Dommy::Event.new("x", "bubbles" => true, "composed" => true)
    deep.dispatch_event(event)
    assert_same(host, event.__js_get__("target"))
  end

  def test_target_survives_a_light_dom_dispatch
    node = @doc.create_element("a")
    @doc.body.append_child(node)
    event = Dommy::Event.new("z", "bubbles" => true)
    node.dispatch_event(event)
    assert_same(node, event.__js_get__("target"))
  end

  def test_composed_path_crosses_the_boundary
    host, root, deep = build_host
    path = nil
    deep.add_event_listener("w") { |e| path = e.__js_call__("composedPath", []) }
    deep.dispatch_event(Dommy::Event.new("w", "bubbles" => true, "composed" => true))
    assert_same(deep, path[0])
    assert_same(root, path[2])
    assert_same(host, path[3])
    assert_same(@win, path.last)
  end
end
