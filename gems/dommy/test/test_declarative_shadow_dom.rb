# frozen_string_literal: true

require_relative "test_helper"

# ShadowRoot state (DOM: clonable, serializable, declarative, available to
# element internals) and attachShadow()'s ShadowRootInit.
class TestShadowRootInitState < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
  end

  def test_flags_default_to_false
    root = @host.attach_shadow({"mode" => "open"})
    refute root.clonable
    refute root.serializable
    refute root.__internal_declarative__?
    assert_equal false, root.__js_get__("clonable")
    assert_equal false, root.__js_get__("serializable")
  end

  def test_init_sets_clonable_and_serializable
    root = @host.attach_shadow({"mode" => "open", "clonable" => true, "serializable" => 1})
    assert_equal true, root.__js_get__("clonable")
    assert_equal true, root.__js_get__("serializable")
  end

  def test_slot_assignment_is_an_enum
    assert_raises(Dommy::Bridge::TypeError) { @host.attach_shadow({"mode" => "open", "slotAssignment" => "bogus"}) }
    root = @host.attach_shadow({"mode" => "open", "slotAssignment" => "manual"})
    assert_equal "manual", root.slot_assignment
  end

  # The dictionary is converted before the algorithm runs: a missing mode on
  # an element that cannot host a shadow root is still a TypeError.
  def test_dictionary_conversion_precedes_the_host_check
    span = @doc.create_element("input")
    assert_raises(Dommy::Bridge::TypeError) { span.attach_shadow({}) }
    assert_raises(Dommy::DOMException::NotSupportedError) { span.attach_shadow({"mode" => "open"}) }
  end

  # attach a shadow root step 4: a declarative shadow root of the same mode
  # is emptied, stops being declarative, and is returned.
  def test_attach_over_a_declarative_root_empties_and_returns_it
    root = @host.attach_shadow({"mode" => "open"})
    root.inner_html = "<span>a</span><b>b</b>"
    root.__internal_declarative__ = true
    assert_raises(Dommy::DOMException::NotSupportedError) { @host.attach_shadow({"mode" => "closed"}) }
    again = @host.attach_shadow({"mode" => "open"})
    assert_same root, again
    assert_equal 0, root.child_nodes.length
    refute root.__internal_declarative__?
    assert_raises(Dommy::DOMException::NotSupportedError) { @host.attach_shadow({"mode" => "open"}) }
  end

  def test_attach_over_an_imperative_root_throws
    @host.attach_shadow({"mode" => "open"})
    assert_raises(Dommy::DOMException::NotSupportedError) { @host.attach_shadow({"mode" => "open"}) }
  end

  # Emptying a declarative root removes the children one at a time, in tree
  # order: a MutationObserver sees one record per child.
  def test_emptying_a_declarative_root_queues_a_record_per_child
    root = @host.attach_shadow({"mode" => "open"})
    root.inner_html = "<i></i><b></b>"
    root.__internal_declarative__ = true
    observer = Dommy::MutationObserver.new(@win, proc {})
    observer.__js_call__("observe", [root, {"childList" => true}])
    @host.attach_shadow({"mode" => "open"})
    records = observer.__js_call__("takeRecords", [])
    assert_equal 2, records.size
    assert_equal(%w[I B], records.map { |r| r.__js_get__("removedNodes").first.tag_name })
  end
end

# The HTML fragment serialization algorithm with serializableShadowRoots and
# shadowRoots (getHTML), and an element's is value.
class TestShadowRootSerialization < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='w'><span id='h'>light</span></div>")
    @doc = @win.document
    @wrapper = @doc.get_element_by_id("w")
    @host = @doc.get_element_by_id("h")
  end

  def test_inner_html_never_serializes_shadow_roots
    root = @host.attach_shadow({"mode" => "open", "serializable" => true})
    root.inner_html = "<slot></slot>"
    assert_equal '<span id="h">light</span>', @wrapper.inner_html
    assert_equal '<span id="h">light</span>', @wrapper.get_html
    assert_equal '<span id="h">light</span>', @wrapper.get_html({"serializableShadowRoots" => false})
  end

  def test_serializable_shadow_root_comes_before_the_children
    root = @host.attach_shadow({"mode" => "open", "serializable" => true})
    root.inner_html = "<slot></slot>"
    assert_equal '<span id="h"><template shadowrootmode="open" shadowrootserializable=""><slot></slot></template>light</span>',
                 @wrapper.get_html({"serializableShadowRoots" => true})
    assert_equal '<template shadowrootmode="open" shadowrootserializable=""><slot></slot></template>light',
                 @host.get_html({"serializableShadowRoots" => true})
  end

  def test_a_listed_root_is_serialized_whatever_its_flag
    root = @host.attach_shadow({"mode" => "closed", "delegatesFocus" => true, "clonable" => true,
                                "slotAssignment" => "manual"})
    root.inner_html = "<b>x</b>"
    assert_equal '<span id="h">light</span>', @wrapper.get_html({"serializableShadowRoots" => true})
    assert_equal '<span id="h"><template shadowrootmode="closed" shadowrootdelegatesfocus="" ' \
                 'shadowrootslotassignment="manual" shadowrootclonable=""><b>x</b></template>light</span>',
                 @wrapper.get_html({"shadowRoots" => [root]})
  end

  def test_nested_shadow_roots_and_shadow_root_get_html
    outer = @host.attach_shadow({"mode" => "open", "serializable" => true})
    outer.inner_html = "<div id='inner'></div>"
    inner = outer.get_element_by_id("inner").attach_shadow({"mode" => "open", "serializable" => true})
    inner.inner_html = "<i>deep</i>"
    assert_equal '<div id="inner"><template shadowrootmode="open" shadowrootserializable=""><i>deep</i></template></div>',
                 outer.get_html({"serializableShadowRoots" => true})
    assert_equal '<div id="inner"></div>', outer.inner_html
  end

  def test_hosts_inside_template_contents
    @wrapper.inner_html = "<template><p id='t'></p></template>"
    p_el = @wrapper.first_element_child.content.first_element_child
    root = p_el.attach_shadow({"mode" => "open", "serializable" => true})
    root.inner_html = "s"
    assert_equal '<template><p id="t"><template shadowrootmode="open" shadowrootserializable="">s</template></p></template>',
                 @wrapper.get_html({"serializableShadowRoots" => true})
  end

  def test_text_and_attributes_are_escaped
    root = @host.attach_shadow({"mode" => "open", "serializable" => true})
    root.inner_html = %(<b title='a"&lt;'>x &amp;  y</b><script>a<b</script>)
    assert_equal %(<template shadowrootmode="open" shadowrootserializable=""><b title="a&quot;&lt;">x &amp; &nbsp;y</b>) +
                 %(<script>a<b</script></template>light),
                 @host.get_html({"serializableShadowRoots" => true})
  end

  def test_shadow_roots_must_be_shadow_roots
    assert_raises(Dommy::Bridge::TypeError) { @wrapper.get_html({"shadowRoots" => [@host]}) }
    assert_raises(Dommy::Bridge::TypeError) { @wrapper.get_html(5) }
  end

  # "If current node's is value is not null, and the element does not have
  # an is attribute": an element created with {is} serializes one.
  def test_is_value_without_an_is_attribute
    button = @doc.create_element("button", {"is" => "x-button"})
    button.set_attribute("type", "submit")
    @wrapper.append_child(button)
    assert_equal '<button is="x-button" type="submit"></button>', button.outer_html
    assert_includes @wrapper.inner_html, '<button is="x-button" type="submit"></button>'
    attributed = @doc.create_element("button", {"is" => "x-button"})
    attributed.set_attribute("is", "other")
    assert_equal '<button is="other"></button>', attributed.outer_html
  end

  def test_void_element_get_html_is_empty
    br = @doc.create_element("br")
    assert_equal "", br.get_html({"serializableShadowRoots" => true})
  end
end
