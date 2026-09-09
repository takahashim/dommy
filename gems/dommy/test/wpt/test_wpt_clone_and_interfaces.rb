# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for the <template> cloning steps, Document.isConnected, and
# the interface an undefined custom element gets.
#
# WPT: html/semantics/scripting-1/the-template-element/template-content-cloning
#      dom/nodes/Node-isConnected.html
#      custom-elements/Document-createElement.html
class TestWPTTemplateCloningSteps < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @host = @doc.create_element("div")
    @doc.body.append_child(@host)
  end

  def test_deep_clone_copies_the_content_fragment
    @host.inner_html = "<template><p>x</p></template>"
    clone = @host.first_child.clone_node(true)
    assert_equal(1, clone.content.child_nodes.length)
    assert_equal("<p>x</p>", clone.content.child_nodes[0].outer_html)
  end

  def test_shallow_clone_leaves_the_content_empty
    @host.inner_html = "<template><p>x</p></template>"
    clone = @host.first_child.clone_node(false)
    assert_equal(0, clone.content.child_nodes.length)
  end

  def test_cloned_content_is_independent_of_the_source
    @host.inner_html = "<template><p>x</p></template>"
    template = @host.first_child
    clone = template.clone_node(true)
    clone.content.first_child.text_content = "changed"
    assert_equal("x", template.content.first_child.text_content)
    assert_equal("changed", clone.content.first_child.text_content)
  end

  def test_template_nested_in_a_deep_clone_keeps_its_content
    @host.inner_html = "<section><template><b>n</b></template></section>"
    clone = @host.first_child.clone_node(true)
    assert_equal(1, clone.first_child.content.child_nodes.length)
    assert_equal("<b>n</b>", clone.first_child.content.first_child.outer_html)
  end

  def test_cloned_template_has_no_direct_children
    @host.inner_html = "<template><p>x</p></template>"
    clone = @host.first_child.clone_node(true)
    assert_equal(0, clone.child_nodes.length)
  end

  def test_empty_template_deep_clone_stays_empty
    @host.inner_html = "<template></template>"
    clone = @host.first_child.clone_node(true)
    assert_equal(0, clone.content.child_nodes.length)
  end
end

class TestWPTDocumentIsConnected < Minitest::Test
  include DommyTestHelper

  def test_document_is_connected
    win = make_window
    assert_equal(true, win.document.is_connected?)
    assert_equal(true, win.document.__js_get__("isConnected"))
  end

  def test_attached_and_detached_elements
    win = make_window("<div id='a'></div>")
    doc = win.document
    assert_equal(true, doc.get_element_by_id("a").is_connected?)
    assert_equal(false, doc.create_element("div").is_connected?)
  end
end

class TestWPTUndefinedCustomElementInterface < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  # A valid custom element name that has not been defined is an *undefined
  # custom element*: its interface is HTMLElement, not HTMLUnknownElement.
  def test_valid_custom_element_name_is_an_html_element
    assert_instance_of(Dommy::HTMLElement, @doc.create_element("foo-bar"))
  end

  def test_unknown_name_without_a_hyphen_is_html_unknown_element
    assert_instance_of(Dommy::HTMLUnknownElement, @doc.create_element("foo"))
  end

  def test_reserved_hyphenated_names_are_html_unknown_element
    assert_instance_of(Dommy::HTMLUnknownElement, @doc.create_element("annotation-xml"))
    assert_instance_of(Dommy::HTMLUnknownElement, @doc.create_element("font-face"))
  end

  def test_name_must_start_with_an_ascii_lower_alpha
    # `_foo-bar` is a well-formed element name but not a valid custom element
    # name (which must start with an ASCII lower alpha), so it stays unknown.
    assert_instance_of(Dommy::HTMLUnknownElement, @doc.create_element("_foo-bar"))
  end

  def test_parsed_undefined_custom_element_is_an_html_element
    @doc.body.inner_html = "<my-widget></my-widget>"
    assert_instance_of(Dommy::HTMLElement, @doc.body.first_child)
  end

  def test_defining_the_element_still_upgrades_it
    klass = Class.new(Dommy::HTMLElement)
    @doc.body.inner_html = "<later-defined></later-defined>"
    @win.custom_elements.define("later-defined", klass)
    assert_instance_of(klass, @doc.body.first_child)
  end
end

# WPT: custom-elements/upgrading.html — "upgrade an element" replays the
# attributes the element already had through attributeChangedCallback before
# connectedCallback runs.
class TestWPTCustomElementUpgradeReactions < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @calls = []
    calls = @calls
    @klass = Class.new(Dommy::HTMLElement) do
      define_singleton_method(:observed_attributes) { %w[a b] }
      define_method(:connected_callback) { calls << "connected" }
      define_method(:attribute_changed_callback) do |name, old, value|
        calls << "attr:#{name}:#{old.inspect}:#{value}"
      end
    end
  end

  def test_existing_observed_attributes_are_replayed_before_connected_callback
    el = @doc.create_element("x-replay")
    el.set_attribute("a", "1")
    @doc.body.append_child(el)
    @win.custom_elements.define("x-replay", @klass)
    assert_equal(["attr:a:nil:1", "connected"], @calls)
  end

  def test_unobserved_attributes_are_not_replayed
    el = @doc.create_element("x-replay")
    el.set_attribute("c", "z")
    @doc.body.append_child(el)
    @win.custom_elements.define("x-replay", @klass)
    assert_equal(["connected"], @calls)
  end

  def test_every_observed_attribute_is_replayed
    el = @doc.create_element("x-replay")
    el.set_attribute("a", "1")
    el.set_attribute("b", "2")
    @doc.body.append_child(el)
    @win.custom_elements.define("x-replay", @klass)
    assert_equal(["attr:a:nil:1", "attr:b:nil:2", "connected"], @calls)
  end

  def test_later_mutations_still_report_the_old_value
    el = @doc.create_element("x-replay")
    el.set_attribute("a", "1")
    @doc.body.append_child(el)
    @win.custom_elements.define("x-replay", @klass)
    el.set_attribute("a", "2")
    assert_equal(["attr:a:nil:1", "connected", "attr:a:\"1\":2"], @calls)
  end

  def test_explicit_upgrade_replays_attributes_on_a_detached_subtree
    @win.custom_elements.define("x-replay", @klass)
    host = @doc.create_element("div")
    host.inner_html = "<x-replay a='9'></x-replay>"
    @win.custom_elements.upgrade(host)
    assert_equal(["attr:a:nil:9"], @calls)
  end
end
