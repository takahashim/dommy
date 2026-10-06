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

# DOM "clone a node" step 6: a clonable shadow root is cloned with its host.
class TestShadowRootCloning < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
  end

  def test_clonable_root_is_cloned_deep_and_shallow
    root = @host.attach_shadow({"mode" => "open", "clonable" => true, "serializable" => true, "delegatesFocus" => true,
                                "slotAssignment" => "manual"})
    root.inner_html = "<input><div><span></span></div>"
    @host.append_child(@doc.create_element("p"))
    [true, false].each do |deep|
      clone = @host.clone_node(deep)
      copy = clone.shadow_root
      refute_nil copy
      refute_same root, copy
      assert copy.clonable
      assert copy.serializable
      assert copy.delegates_focus
      assert_equal "manual", copy.slot_assignment
      assert_equal "<input><div><span></span></div>", copy.inner_html
      assert_equal(deep ? 1 : 0, clone.child_nodes.length)
    end
  end

  def test_non_clonable_root_is_not_cloned
    @host.attach_shadow({"mode" => "open"}).inner_html = "<i></i>"
    assert_nil @host.clone_node(true).shadow_root
  end

  def test_closed_and_declarative_state_carry_over
    root = @host.attach_shadow({"mode" => "closed", "clonable" => true})
    root.__internal_declarative__ = true
    clone = @host.clone_node(true)
    copy = clone.__internal_shadow_root__
    assert_equal "closed", copy.mode
    assert copy.__internal_declarative__?
  end

  def test_descendant_hosts_nested_shadows_and_template_contents
    outer = @doc.create_element("div")
    outer.append_child(@host)
    root = @host.attach_shadow({"mode" => "open", "clonable" => true})
    root.inner_html = "<div id='in'></div>"
    root.get_element_by_id("in").attach_shadow({"mode" => "open", "clonable" => true}).inner_html = "deep"
    template = @doc.create_element("template")
    template.content.append_child(outer)
    clone = template.clone_node(true)
    host_copy = clone.content.first_element_child.first_element_child
    refute_nil host_copy.shadow_root
    assert_equal "deep", host_copy.shadow_root.get_element_by_id("in").shadow_root.inner_html
  end

  def test_import_node_and_range_clone
    @host.attach_shadow({"mode" => "open", "clonable" => true}).inner_html = "<b>x</b>"
    other = Dommy::Window.new.document
    imported = other.import_node(@host, true)
    assert_equal "<b>x</b>", imported.shadow_root.inner_html
    assert_same other, imported.shadow_root.document

    range = @doc.create_range
    range.select_node(@host)
    fragment = range.clone_contents
    assert_equal "<b>x</b>", fragment.first_child.shadow_root.inner_html
  end
end

# Declarative shadow roots from the document's parser (a pass over the
# parsed tree emulating the tree builder's template start tag steps).
class TestDeclarativeShadowRootsFromThePageParser < Minitest::Test
  def parse(body)
    Dommy::Window.new(nil, backend_doc: Dommy::Backend.parse("<!doctype html><html><head></head><body>#{body}</body></html>"))
  end

  def test_basic_attachment_and_flags
    doc = parse("<div id=h><template shadowrootmode=open shadowrootdelegatesfocus shadowrootserializable " \
                "shadowrootclonable shadowrootslotassignment=MANUAL><slot></slot></template><p>light</p></div>").document
    host = doc.get_element_by_id("h")
    root = host.shadow_root
    refute_nil root
    assert_equal "<slot></slot>", root.inner_html
    assert_equal "<p>light</p>", host.inner_html
    assert root.delegates_focus
    assert root.serializable
    assert root.clonable
    assert_equal "manual", root.slot_assignment
    assert root.__internal_declarative__?
    assert root.__internal_available_to_internals__?
    assert doc.__internal_allow_declarative_shadow_roots__?
  end

  def test_mode_is_case_insensitive_and_invalid_modes_stay_templates
    doc = parse("<div id=a><template shadowrootmode=OPEN>x</template></div>" \
                "<div id=b><template shadowrootmode=closed>y</template></div>" \
                "<div id=c><template shadowrootmode=bogus>z</template></div>").document
    refute_nil doc.get_element_by_id("a").shadow_root
    b = doc.get_element_by_id("b")
    assert_nil b.shadow_root
    assert_equal "closed", b.__internal_shadow_root__.mode
    assert_equal "", b.inner_html
    c = doc.get_element_by_id("c")
    assert_nil c.__internal_shadow_root__
    assert_equal "z", c.query_selector("template").content.text_content
  end

  def test_first_template_wins_and_the_rest_stay
    doc = parse("<div id=h><template shadowrootmode=open>1</template><template shadowrootmode=closed>2</template></div>").document
    host = doc.get_element_by_id("h")
    assert_equal "1", host.shadow_root.inner_html
    leftover = host.query_selector("template")
    assert_equal "closed", leftover.get_attribute("shadowrootmode")
    assert_equal "2", leftover.content.text_content
  end

  def test_invalid_hosts_keep_the_template
    doc = parse("<progress id=p><template shadowrootmode=open>x</template></progress>" \
                "<template id=t><template shadowrootmode=open>y</template></template>").document
    assert doc.get_element_by_id("p").query_selector("template")
    inner = doc.get_element_by_id("t").content.first_element_child
    assert_equal "open", inner.get_attribute("shadowrootmode")
  end

  def test_nested_and_inside_template_contents
    doc = parse("<div id=h><template shadowrootmode=open><span id=i><template shadowrootmode=open>deep</template></span>" \
                "</template></div><template id=t><div id=x><template shadowrootmode=open>tc</template></div></template>").document
    inner = doc.get_element_by_id("h").shadow_root.get_element_by_id("i")
    assert_equal "deep", inner.shadow_root.inner_html
    x = doc.get_element_by_id("t").content.query_selector("#x")
    assert_equal "tc", x.shadow_root.inner_html
  end

  # The template was never in the tree, so the text on either side of it is
  # one Text node, as the parser appended it.
  def test_text_around_the_template_is_one_node
    doc = parse("<div id=h>a<template shadowrootmode=open></template>b</div>").document
    host = doc.get_element_by_id("h")
    assert_equal 1, host.child_nodes.length
    assert_equal "ab", host.first_child.data
  end

  def test_registry_attribute_gives_a_null_registry_kept_on_adoption
    doc = parse("<div id=h><template shadowrootmode=open shadowrootcustomelementregistry></template></div>").document
    root = doc.get_element_by_id("h").shadow_root
    assert root.__internal_custom_element_registry__.nil?
    assert root.__internal_keep_registry_null__?
    assert_equal '<template shadowrootmode="open" shadowrootcustomelementregistry=""></template>',
                 doc.get_element_by_id("h").get_html({"shadowRoots" => [root]})
  end

  def test_parser_scripts_come_in_parse_order
    doc = parse("<div id=h><script>a</script><template shadowrootmode=open><script>b</script></template>" \
                "<script>c</script></div><script>d</script>").document
    assert_equal %w[a b c d], doc.__internal_parser_scripts__.map(&:text_content)
    assert_equal %w[a c d], doc.scripts.to_a.map(&:text_content)
  end

  def test_dommy_parse_of_a_body_fragment
    doc = Dommy.parse("<div id=h><template shadowrootmode=open>s</template></div>").document
    refute_nil doc.get_element_by_id("h").shadow_root
  end

  def test_documents_without_a_browsing_context_do_not_allow_them
    win = parse("")
    html_doc = win.document.implementation.create_html_document("")
    refute html_doc.__internal_allow_declarative_shadow_roots__?
    parsed = Dommy::DOMParser.new.parse_from_string("<div id=h><template shadowrootmode=open></template></div>", "text/html")
    assert_nil parsed.get_element_by_id("h").__internal_shadow_root__
    assert win.document.clone_node(false).__internal_allow_declarative_shadow_roots__?
  end

  def test_fragment_parsing_setters_do_not_allow_them
    doc = parse("<div id=w></div>").document
    w = doc.get_element_by_id("w")
    w.inner_html = "<div id=h><template shadowrootmode=open></template></div>"
    assert_nil doc.get_element_by_id("h").__internal_shadow_root__
    w.insert_adjacent_html("beforeend", "<p id=q><template shadowrootmode=open></template></p>")
    assert_nil doc.get_element_by_id("q").__internal_shadow_root__
  end
end
