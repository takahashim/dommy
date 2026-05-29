# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Shadow DOM.
# WPT: shadow-dom/Element-interface-attachShadow.html,
# Element-interface-shadowRoot-attribute.html,
# event-composed.html, event-composed-path.html,
# slots.html, slots-fallback-content.html
class TestWPTShadowAttach < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
  end

  # ---- attachShadow result ----
  # WPT: Element-interface-attachShadow.html

  def test_attachShadow_returns_ShadowRoot
    sr = @host.attach_shadow({"mode" => "open"})
    assert_kind_of(Dommy::ShadowRoot, sr)
  end

  def test_attachShadow_missing_mode_raises_TypeError
    # Spec: `mode` is a required field of ShadowRootInit.
    assert_raises(TypeError) { @host.attach_shadow }
  end

  def test_attachShadow_empty_init_raises_TypeError
    assert_raises(TypeError) { @host.attach_shadow({}) }
  end

  def test_attachShadow_on_input_raises_NotSupportedError
    inp = @doc.create_element("input")
    assert_raises(Dommy::DOMException::NotSupportedError) do
      inp.attach_shadow({"mode" => "open"})
    end
  end

  def test_attachShadow_on_custom_element_name_allowed
    el = @doc.create_element("my-card")
    sr = el.attach_shadow({"mode" => "open"})
    assert_kind_of(Dommy::ShadowRoot, sr)
  end

  def test_attachShadow_open_mode_recorded
    assert_equal("open", @host.attach_shadow({"mode" => "open"}).mode)
  end

  def test_attachShadow_closed_mode_recorded
    assert_equal("closed", @host.attach_shadow({"mode" => "closed"}).mode)
  end

  def test_attachShadow_host_back_reference
    sr = @host.attach_shadow({"mode" => "open"})
    assert_same(@host, sr.host)
  end

  def test_attachShadow_nodeType_is_document_fragment
    sr = @host.attach_shadow({"mode" => "open"})
    assert_equal(11, sr.__js_get__("nodeType"))
  end

  def test_attachShadow_default_slotAssignment_named
    sr = @host.attach_shadow({"mode" => "open"})
    assert_equal("named", sr.__js_get__("slotAssignment"))
  end

  def test_attachShadow_manual_slotAssignment
    sr = @host.attach_shadow({"mode" => "open", "slotAssignment" => "manual"})
    assert_equal("manual", sr.__js_get__("slotAssignment"))
  end

  # ---- attachShadow errors ----

  def test_attachShadow_invalid_mode_raises_SyntaxError
    assert_raises(Dommy::DOMException::SyntaxError) { @host.attach_shadow({"mode" => "wrong"}) }
  end

  def test_attachShadow_twice_raises_InvalidStateError
    @host.attach_shadow({"mode" => "open"})
    assert_raises(Dommy::DOMException::InvalidStateError) { @host.attach_shadow({"mode" => "open"}) }
  end

  # ---- shadowRoot accessor ----
  # WPT: Element-interface-shadowRoot-attribute.html

  def test_shadowRoot_returns_open_root
    sr = @host.attach_shadow({"mode" => "open"})
    assert_same(sr, @host.shadow_root)
  end

  def test_shadowRoot_returns_nil_for_closed
    @host.attach_shadow({"mode" => "closed"})
    assert_nil(@host.shadow_root)
  end

  def test_shadowRoot_returns_nil_before_attach
    assert_nil(@host.shadow_root)
  end
end

class TestWPTShadowEncapsulation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'><p id='light'>L</p></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
    @sr = @host.attach_shadow({"mode" => "open"})
    @sr.inner_html = "<span id='in-shadow'>S</span><button class='go'>Go</button>"
  end

  # ---- queries don't reach across shadow boundary ----
  # WPT: shadow-dom/Document-Element-queryselector*.html

  def test_outer_query_selector_does_not_find_shadow_id
    assert_nil(@doc.query_selector("#in-shadow"))
  end

  def test_outer_query_selector_does_not_find_shadow_class
    assert_nil(@doc.query_selector(".go"))
  end

  def test_outer_query_selector_all_does_not_find_shadow
    list = @doc.query_selector_all("span, button")
    refute(list.any? { |el| el.id == "in-shadow" })
  end

  def test_outer_getElementById_does_not_find_shadow_node
    assert_nil(@doc.get_element_by_id("in-shadow"))
  end

  def test_outer_children_excludes_shadow_tree
    light = @host.children
    assert_equal(1, light.length)
    assert_equal("P", light[0].tag_name)
  end

  def test_inner_query_selector_finds_shadow_node
    refute_nil(@sr.query_selector("#in-shadow"))
  end

  def test_inner_query_selector_does_not_find_light_node
    # Light DOM (in the host) is NOT inside the shadow tree.
    assert_nil(@sr.query_selector("#light"))
  end

  def test_shadow_inner_html_isolated_from_document
    @sr.inner_html = "<i>italic</i>"
    assert_equal("<i>italic</i>", @sr.inner_html)
    assert_nil(@doc.query_selector("i"))
  end

  def test_text_content_aggregates_shadow_subtree
    @sr.inner_html = "<p>foo</p><p>bar</p>"
    assert_equal("foobar", @sr.text_content)
  end
end

class TestWPTShadowSlots < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  # ---- assignedNodes / assignedElements ----
  # WPT: shadow-dom/slots.html, slots-assignedNodes.html

  def test_default_slot_picks_unslotted_children
    @doc.body.inner_html = "<div id='h'><p id='a'>A</p><span id='b'>B</span></div>"
    host = @doc.get_element_by_id("h")
    sr = host.attach_shadow({"mode" => "open"})
    sr.inner_html = "<slot></slot>"
    slot = sr.query_selector("slot")
    assigned = slot.assigned_elements
    assert_equal(["a", "b"], assigned.map(&:id))
  end

  def test_named_slot_filters_by_slot_attribute
    @doc.body.inner_html = "<div id='h'><p slot='lead'>L</p><span>def</span></div>"
    host = @doc.get_element_by_id("h")
    sr = host.attach_shadow({"mode" => "open"})
    sr.inner_html = "<slot name='lead'></slot><slot></slot>"
    lead = sr.query_selector("slot[name='lead']")
    deflt = sr.query_selector("slot:not([name])") || sr.query_selector_all("slot")[1]
    assert_equal("P", lead.assigned_elements[0].tag_name)
    assert_equal("SPAN", deflt.assigned_elements[0].tag_name)
  end

  def test_named_slot_no_match_returns_empty
    @doc.body.inner_html = "<div id='h'><p>plain</p></div>"
    host = @doc.get_element_by_id("h")
    sr = host.attach_shadow({"mode" => "open"})
    sr.inner_html = "<slot name='missing'></slot>"
    slot = sr.query_selector("slot")
    assert_empty(slot.assigned_elements)
  end

  def test_assignedNodes_flatten_falls_back_to_default_content
    @doc.body.inner_html = "<div id='h'></div>"
    host = @doc.get_element_by_id("h")
    sr = host.attach_shadow({"mode" => "open"})
    sr.inner_html = "<slot><em>fallback</em></slot>"
    slot = sr.query_selector("slot")
    flat = slot.assigned_nodes({"flatten" => true})
    refute_empty(flat)
    assert_equal("EM", flat[0].tag_name)
  end

  def test_assignedNodes_no_flatten_does_not_include_fallback
    @doc.body.inner_html = "<div id='h'></div>"
    host = @doc.get_element_by_id("h")
    sr = host.attach_shadow({"mode" => "open"})
    sr.inner_html = "<slot><em>fallback</em></slot>"
    slot = sr.query_selector("slot")
    assert_empty(slot.assigned_nodes)
  end

  # ---- manual slot assignment ----
  # WPT: shadow-dom/slots-imperative-api.html

  def test_manual_slot_assignment_uses_explicit_list
    @doc.body.inner_html = "<div id='h'><p id='a'>A</p><p id='b'>B</p></div>"
    host = @doc.get_element_by_id("h")
    sr = host.attach_shadow({"mode" => "open", "slotAssignment" => "manual"})
    sr.inner_html = "<slot></slot>"
    slot = sr.query_selector("slot")
    only_b = @doc.get_element_by_id("b")
    slot.assign(only_b)
    assert_equal(["b"], slot.assigned_elements.map(&:id))
  end

  def test_manual_assign_fires_slotchange
    @doc.body.inner_html = "<div id='h'><p>x</p></div>"
    host = @doc.get_element_by_id("h")
    sr = host.attach_shadow({"mode" => "open", "slotAssignment" => "manual"})
    sr.inner_html = "<slot></slot>"
    slot = sr.query_selector("slot")
    fired = false
    slot.add_event_listener("slotchange", proc { fired = true })
    slot.assign(host.children[0])
    assert(fired)
  end
end

class TestWPTShadowEvents < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='outer'><div id='host'></div></div>")
    @doc = @win.document
    @outer = @doc.get_element_by_id("outer")
    @host = @doc.get_element_by_id("host")
    @sr = @host.attach_shadow({"mode" => "open"})
    @sr.inner_html = "<button id='btn'>X</button>"
    @btn = @sr.get_element_by_id("btn")
  end

  # ---- composed: false stops at boundary ----
  # WPT: shadow-dom/event-composed.html

  def test_non_composed_event_does_not_cross_shadow_boundary
    seen = false
    @host.add_event_listener("click", proc { seen = true })
    @btn.dispatch_event(Dommy::Event.new("click", "bubbles" => true, "composed" => false))
    refute(seen)
  end

  def test_composed_event_crosses_shadow_boundary_to_host
    seen = false
    @host.add_event_listener("click", proc { seen = true })
    @btn.dispatch_event(Dommy::Event.new("click", "bubbles" => true, "composed" => true))
    assert(seen)
  end

  def test_composed_event_continues_bubbling_past_host
    seen_outer = false
    @outer.add_event_listener("click", proc { seen_outer = true })
    @btn.dispatch_event(Dommy::Event.new("click", "bubbles" => true, "composed" => true))
    assert(seen_outer)
  end

  def test_event_inside_shadow_reaches_shadow_root_listener
    fired = false
    @sr.add_event_listener("click", proc { fired = true })
    @btn.dispatch_event(Dommy::Event.new("click", "bubbles" => true))
    assert(fired)
  end

  # ---- composedPath ----
  # WPT: shadow-dom/event-composed-path.html

  def test_composedPath_includes_shadow_target_for_composed_event
    seen = nil
    @outer.add_event_listener("click", proc { |e| seen = e.__js_call__("composedPath", []) })
    @btn.dispatch_event(Dommy::Event.new("click", "bubbles" => true, "composed" => true))
    refute_nil(seen)
    assert_includes(seen, @btn)
    assert_includes(seen, @outer)
  end

  def test_composedPath_for_non_composed_event_stays_within_shadow
    seen = nil
    @sr.add_event_listener("click", proc { |e| seen = e.__js_call__("composedPath", []) })
    @btn.dispatch_event(Dommy::Event.new("click", "bubbles" => true, "composed" => false))
    refute_nil(seen)
    refute_includes(seen, @host)
  end
end

class TestWPTShadowTree < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
    @sr = @host.attach_shadow({"mode" => "open"})
  end

  # ---- getRootNode ----
  # WPT: shadow-dom/Document-prototype-getRootNode.html (partial)

  def test_getRootNode_inside_shadow_returns_shadow_root
    p = @doc.create_element("p")
    @sr.append_child(p)
    assert_same(@sr, p.get_root_node)
  end

  def test_getRootNode_for_shadow_root_returns_itself
    assert_same(@sr, @sr.get_root_node)
  end

  def test_getRootNode_for_light_dom_returns_document
    p = @doc.create_element("p")
    @doc.body.append(p)
    root = p.get_root_node
    # Light DOM root should be the document.
    assert_kind_of(Dommy::Document, root)
  end

  # ---- contains across boundary ----

  def test_shadow_root_contains_its_descendant
    el = @doc.create_element("p")
    @sr.append_child(el)
    assert(@sr.contains?(el))
  end

  def test_shadow_root_does_not_contain_outer_element
    light = @doc.create_element("p")
    @doc.body.append(light)
    refute(@sr.contains?(light))
  end

  def test_host_does_not_contain_shadow_descendant
    el = @doc.create_element("p")
    @sr.append_child(el)
    # contains() is light-tree only; shadow descendants are not "in" the host.
    refute(@host.contains?(el))
  end
end
