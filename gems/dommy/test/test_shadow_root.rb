# frozen_string_literal: true

require_relative "test_helper"

class TestShadowRootBasics < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
  end

  def test_attach_shadow_default_mode_open
    sr = @host.attach_shadow({"mode" => "open"})
    assert_kind_of(Dommy::ShadowRoot, sr)
    assert_equal("open", sr.mode)
  end

  def test_attach_shadow_explicit_open
    sr = @host.attach_shadow({"mode" => "open"})
    assert_equal("open", sr.mode)
  end

  def test_attach_shadow_closed
    sr = @host.attach_shadow({"mode" => "closed"})
    assert_equal("closed", sr.mode)
  end

  def test_attach_shadow_invalid_mode_raises
    # `mode` is a WebIDL enum → an invalid value throws TypeError, not a DOMException.
    assert_raises(TypeError) { @host.attach_shadow({"mode" => "halfway"}) }
  end

  def test_attach_shadow_twice_raises
    @host.attach_shadow({"mode" => "open"})
    assert_raises(Dommy::DOMException::NotSupportedError) { @host.attach_shadow({"mode" => "open"}) }
  end

  def test_shadow_root_returns_open_root
    sr = @host.attach_shadow({"mode" => "open"})
    assert_equal(sr, @host.shadow_root)
  end

  def test_shadow_root_returns_nil_for_closed
    @host.attach_shadow({"mode" => "closed"})
    assert_nil(@host.shadow_root)
  end

  def test_shadow_root_host_back_reference
    sr = @host.attach_shadow({"mode" => "open"})
    assert_same(@host, sr.host)
  end

  def test_node_type_is_document_fragment
    sr = @host.attach_shadow({"mode" => "open"})
    assert_equal(11, sr.__js_get__("nodeType"))
  end
end

class TestShadowRootEncapsulation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'><p id='light'>Light DOM</p></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
    @sr = @host.attach_shadow({"mode" => "open"})
    @sr.inner_html = "<span id='shadow'>Shadow content</span><button class='action'>Go</button>"
  end

  def test_shadow_invisible_to_outer_query_selector
    # Outer querySelector should not reach inside shadow tree.
    assert_nil(@doc.query_selector("#shadow"))
    assert_nil(@doc.query_selector(".action"))
  end

  def test_shadow_invisible_to_get_element_by_id
    assert_nil(@doc.get_element_by_id("shadow"))
  end

  def test_outer_children_does_not_include_shadow
    light = @host.children
    assert_equal(1, light.size)
    assert_equal("P", light[0].tag_name)
  end

  def test_shadow_query_selector_works
    el = @sr.query_selector("#shadow")
    refute_nil(el)
    assert_equal("Shadow content", el.text_content)
  end

  def test_shadow_query_selector_all
    list = @sr.query_selector_all("span, button")
    assert_equal(2, list.size)
  end

  def test_shadow_get_element_by_id
    el = @sr.get_element_by_id("shadow")
    refute_nil(el)
  end

  def test_inner_html_round_trip
    @sr.inner_html = "<i>italics</i>"
    assert_equal("<i>italics</i>", @sr.inner_html)
    # still isolated
    assert_nil(@doc.query_selector("i"))
  end

  def test_text_content
    @sr.inner_html = "<p>foo</p><p>bar</p>"
    assert_equal("foobar", @sr.text_content)
  end
end

class TestShadowRootTreeOps < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'></div>")
    @doc = @win.document
    @sr = @doc.get_element_by_id("host").attach_shadow({"mode" => "open"})
  end

  def test_append_child
    el = @doc.create_element("p")
    el.text_content = "added"
    @sr.append_child(el)
    assert_equal(1, @sr.child_element_count)
  end

  def test_append_with_string_and_node
    @sr.append("first ", @doc.create_element("em"), " last")
    assert_equal(3, @sr.__dommy_backend_node__.children.size)
  end

  def test_prepend_with_text
    @sr.append_child(@doc.create_element("p"))
    @sr.prepend("hello ")
    assert_equal("hello ", @sr.__dommy_backend_node__.children[0].content)
  end

  def test_replace_children_clears_and_inserts
    @sr.append_child(@doc.create_element("p"))
    @sr.replace_children(@doc.create_element("span"), "tail")
    assert_equal(2, @sr.__dommy_backend_node__.children.size)
    assert_equal("SPAN", @sr.children[0].tag_name)
  end

  def test_first_last_child_helpers
    @sr.append("text", @doc.create_element("em"))
    refute_nil(@sr.first_child)
    refute_nil(@sr.last_child)
  end

  def test_first_last_element_child
    @sr.append("text", @doc.create_element("em"), @doc.create_element("strong"))
    assert_equal("EM", @sr.first_element_child.tag_name)
    assert_equal("STRONG", @sr.last_element_child.tag_name)
  end

  def test_get_root_node_returns_shadow_root
    @sr.append_child(@doc.create_element("p"))
    p = @sr.children[0]
    assert_same(@sr, @sr.get_root_node)
    # Element#root_node walks until the shadow boundary too.
    refute_nil(p.root_node)
  end

  def test_get_root_node_composed_crosses_boundary
    @sr.append_child(@doc.create_element("p"))
    p = @sr.children[0]
    # A node inside the shadow tree reports the shadow root by default, but the
    # document under {composed: true} (crossing the boundary via the host).
    assert_same(@sr, p.root_node)
    assert_same(@doc, p.root_node({"composed" => true}))
    # The shadow root itself resolves to the document under composed, too.
    assert_same(@sr, @sr.get_root_node)
    assert_same(@doc, @sr.get_root_node({"composed" => true}))
  end

  def test_node_name_is_document_fragment
    assert_equal("#document-fragment", @sr.__js_get__("nodeName"))
  end

  def test_shadow_contains_its_descendants
    el = @doc.create_element("p")
    @sr.append_child(el)
    assert(@sr.contains?(el))
  end

  def test_shadow_does_not_contain_outer_element
    light = @doc.create_element("p")
    @doc.body.append(light)
    refute(@sr.contains?(light))
  end
end

class TestShadowRootEvents < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
    @sr = @host.attach_shadow({"mode" => "open"})
    @sr.inner_html = "<button id='btn'>X</button>"
    @btn = @sr.get_element_by_id("btn")
  end

  def test_event_listener_on_shadow_root
    fired = false
    @sr.add_event_listener("click", proc { fired = true })
    @sr.dispatch_event(Dommy::Event.new("click"))
    assert(fired)
  end

  def test_event_inside_shadow_does_not_bubble_to_host_by_default
    seen_outside = false
    @host.add_event_listener("click", proc { seen_outside = true })
    # default Event bubbles, but should stop at shadow boundary
    @btn.click
    refute(seen_outside, "Non-composed event must not cross shadow boundary")
  end
end
