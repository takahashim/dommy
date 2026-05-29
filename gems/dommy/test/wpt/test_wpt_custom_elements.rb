# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for CustomElementRegistry.
# WPT: custom-elements/CustomElementRegistry.html, connected-callbacks.html,
# disconnected-callbacks.html, attribute-changed-callback.html,
# Document-createElement.html, reactions/*
class TestWPTCustomElementsRegistry < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @registry = @win.custom_elements
  end

  # ---- define: name validation ----
  # WPT: CustomElementRegistry.html "must throw with an invalid name"

  def test_define_rejects_empty_name
    assert_raises(Dommy::DOMException::SyntaxError) { @registry.define("", Class.new(Dommy::HTMLElement)) }
  end

  def test_define_rejects_name_without_dash
    assert_raises(Dommy::DOMException::SyntaxError) { @registry.define("abc", Class.new(Dommy::HTMLElement)) }
  end

  def test_define_rejects_uppercase_in_name
    assert_raises(Dommy::DOMException::SyntaxError) { @registry.define("a-Bc", Class.new(Dommy::HTMLElement)) }
  end

  def test_define_accepts_simple_hyphenated_name
    @registry.define("a-b", Class.new(Dommy::HTMLElement))
    refute_nil(@registry.get("a-b"))
  end

  def test_define_accepts_multi_hyphen_name
    @registry.define("a-b-c-d", Class.new(Dommy::HTMLElement))
    refute_nil(@registry.get("a-b-c-d"))
  end

  def test_define_accepts_digit_after_hyphen
    @registry.define("x-1", Class.new(Dommy::HTMLElement))
    refute_nil(@registry.get("x-1"))
  end

  # ---- define: duplicate detection ----
  # WPT: CustomElementRegistry.html "must throw when there is already a custom element of the same name"

  def test_define_throws_on_duplicate_name
    @registry.define("dup-name", Class.new(Dommy::HTMLElement))
    assert_raises(Dommy::DOMException::NotSupportedError) do
      @registry.define("dup-name", Class.new(Dommy::HTMLElement))
    end
  end

  # ---- get ----
  # WPT: CustomElementRegistry.html (multiple)

  def test_get_returns_registered_constructor
    klass = Class.new(Dommy::HTMLElement)
    @registry.define("foo-bar", klass)
    assert_same(klass, @registry.get("foo-bar"))
  end

  def test_get_returns_nil_for_unknown_name
    assert_nil(@registry.get("not-registered"))
  end

  def test_get_distinguishes_names
    a = Class.new(Dommy::HTMLElement)
    b = Class.new(Dommy::HTMLElement)
    @registry.define("klass-a", a)
    @registry.define("klass-b", b)
    assert_same(a, @registry.get("klass-a"))
    assert_same(b, @registry.get("klass-b"))
  end

  # ---- getName ----
  # WPT: CustomElementRegistry-getName.html

  def test_getName_returns_registered_name
    klass = Class.new(Dommy::HTMLElement)
    @registry.define("named-thing", klass)
    assert_equal("named-thing", @registry.get_name(klass))
  end

  def test_getName_returns_nil_for_unknown_class
    assert_nil(@registry.get_name(Class.new(Dommy::HTMLElement)))
  end

  # ---- whenDefined ----
  # WPT: reactions/CustomElementRegistry.html, whenDefined.html

  def test_whenDefined_resolves_immediately_when_already_defined
    klass = Class.new(Dommy::HTMLElement)
    @registry.define("ready-now", klass)
    seen = nil
    @registry.when_defined("ready-now").__js_call__("then", [proc { |k| seen = k }])
    @win.scheduler.drain_microtasks
    assert_same(klass, seen)
  end

  def test_whenDefined_resolves_after_subsequent_define
    klass = Class.new(Dommy::HTMLElement)
    seen = nil
    @registry.when_defined("late-1").__js_call__("then", [proc { |k| seen = k }])
    @registry.define("late-1", klass)
    @win.scheduler.drain_microtasks
    assert_same(klass, seen)
  end

  def test_whenDefined_multiple_callers_each_resolve
    klass = Class.new(Dommy::HTMLElement)
    seen = []
    @registry.when_defined("late-2").__js_call__("then", [proc { |k| seen << [:a, k] }])
    @registry.when_defined("late-2").__js_call__("then", [proc { |k| seen << [:b, k] }])
    @registry.define("late-2", klass)
    @win.scheduler.drain_microtasks
    assert_equal([[:a, klass], [:b, klass]], seen)
  end

  def test_whenDefined_unrelated_name_does_not_resolve
    seen = false
    @registry.when_defined("never-arrives").__js_call__("then", [proc { seen = true }])
    @registry.define("other-thing", Class.new(Dommy::HTMLElement))
    @win.scheduler.drain_microtasks
    refute(seen)
  end
end

class TestWPTCustomElementsCreateElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @registry = @win.custom_elements
  end

  # WPT: Document-createElement.html

  def test_createElement_uses_registered_class
    klass = Class.new(Dommy::HTMLElement)
    @registry.define("a-card", klass)
    assert_kind_of(klass, @doc.create_element("a-card"))
  end

  def test_createElement_returns_plain_Element_for_unknown_hyphenated_name
    el = @doc.create_element("undefined-elt")
    assert_kind_of(Dommy::Element, el)
  end

  def test_createElement_preserves_subclass_after_attribute_set
    klass = Class.new(Dommy::HTMLElement)
    @registry.define("k-set", klass)
    el = @doc.create_element("k-set")
    el.set_attribute("data-x", "1")
    # Subclass identity must survive attribute mutation.
    assert_kind_of(klass, el)
  end

  def test_createElement_distinct_instances
    klass = Class.new(Dommy::HTMLElement)
    @registry.define("m-inst", klass)
    a = @doc.create_element("m-inst")
    b = @doc.create_element("m-inst")
    refute_same(a, b)
  end
end

class TestWPTCustomElementsConnected < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @registry = @win.custom_elements
  end

  def make_klass(&block)
    Class.new(Dommy::HTMLElement) do
      attr_accessor(:connected_count, :disconnected_count)
      define_method(:connected_callback) { @connected_count = (@connected_count || 0) + 1 }
      define_method(:disconnected_callback) { @disconnected_count = (@disconnected_count || 0) + 1 }
      class_exec(&block) if block
    end
  end

  # ---- connectedCallback ----
  # WPT: connected-callbacks.html

  def test_connectedCallback_fires_on_append
    @registry.define("c-1", make_klass)
    el = @doc.create_element("c-1")
    @doc.body.append(el)
    assert_equal(1, el.connected_count)
  end

  def test_connectedCallback_fires_on_insertBefore
    @registry.define("c-2", make_klass)
    el = @doc.create_element("c-2")
    @doc.body.append(@doc.create_element("p"))
    @doc.body.insert_before(el, @doc.body.first_element_child)
    assert_equal(1, el.connected_count)
  end

  def test_connectedCallback_fires_via_innerHTML_set
    @registry.define("c-3", make_klass)
    @doc.body.inner_html = "<c-3 id='x'></c-3>"
    el = @doc.get_element_by_id("x")
    assert_equal(1, el.connected_count)
  end

  def test_connectedCallback_not_fired_when_only_created
    @registry.define("c-4", make_klass)
    el = @doc.create_element("c-4")
    assert_nil(el.connected_count)
  end

  def test_connectedCallback_fires_again_after_reattach
    @registry.define("c-5", make_klass)
    el = @doc.create_element("c-5")
    @doc.body.append(el)
    el.remove
    @doc.body.append(el)
    assert_equal(2, el.connected_count)
  end

  # ---- disconnectedCallback ----
  # WPT: disconnected-callbacks.html

  def test_disconnectedCallback_fires_on_remove
    @registry.define("d-1", make_klass)
    el = @doc.create_element("d-1")
    @doc.body.append(el)
    el.remove
    assert_equal(1, el.disconnected_count)
  end

  def test_disconnectedCallback_not_fired_for_unattached
    @registry.define("d-2", make_klass)
    el = @doc.create_element("d-2")
    # remove without ever attaching is a no-op
    el.remove
    assert_nil(el.disconnected_count)
  end

  def test_disconnectedCallback_fires_when_parent_removed
    @registry.define("d-3", make_klass)
    parent = @doc.create_element("div")
    el = @doc.create_element("d-3")
    parent.append(el)
    @doc.body.append(parent)
    parent.remove
    assert_equal(1, el.disconnected_count)
  end
end

class TestWPTCustomElementsAttributes < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @registry = @win.custom_elements
  end

  def make_klass(observed)
    Class.new(Dommy::HTMLElement) do
      define_singleton_method(:observed_attributes) { observed }
      attr_accessor(:attribute_changes)
      define_method(:attribute_changed_callback) do |name, old, new|
        @attribute_changes ||= []
        @attribute_changes << [name, old, new]
      end
    end
  end

  # WPT: attribute-changed-callback.html, reactions/CustomElementRegistry.html

  def test_attributeChangedCallback_fires_for_observed_attribute
    @registry.define("a-1", make_klass(["data-state"]))
    el = @doc.create_element("a-1")
    el.set_attribute("data-state", "on")
    assert_equal([["data-state", nil, "on"]], el.attribute_changes)
  end

  def test_attributeChangedCallback_ignores_unobserved_attributes
    @registry.define("a-2", make_klass(["data-watched"]))
    el = @doc.create_element("a-2")
    el.set_attribute("data-other", "x")
    assert_nil(el.attribute_changes)
  end

  def test_attributeChangedCallback_passes_old_value
    @registry.define("a-3", make_klass(["data-v"]))
    el = @doc.create_element("a-3")
    el.set_attribute("data-v", "first")
    el.set_attribute("data-v", "second")
    assert_equal(["data-v", "first", "second"], el.attribute_changes.last)
  end

  def test_attributeChangedCallback_remove_attribute_passes_nil_new
    @registry.define("a-4", make_klass(["data-r"]))
    el = @doc.create_element("a-4")
    el.set_attribute("data-r", "x")
    el.remove_attribute("data-r")
    assert_equal(["data-r", "x", nil], el.attribute_changes.last)
  end

  def test_attributeChangedCallback_multiple_observed_attrs
    @registry.define("a-5", make_klass(["data-a", "data-b"]))
    el = @doc.create_element("a-5")
    el.set_attribute("data-a", "1")
    el.set_attribute("data-b", "2")
    assert_equal([["data-a", nil, "1"], ["data-b", nil, "2"]], el.attribute_changes)
  end

  def test_attributeChangedCallback_no_observed_attribute_list
    klass = Class.new(Dommy::HTMLElement) do
      attr_accessor(:attribute_changes)
      define_method(:attribute_changed_callback) do |name, old, new|
        @attribute_changes ||= []
        @attribute_changes << [name, old, new]
      end
    end

    @registry.define("a-6", klass)
    el = @doc.create_element("a-6")
    el.set_attribute("data-x", "v")
    # Without observed_attributes, no callbacks should fire.
    assert_nil(el.attribute_changes)
  end
end

class TestWPTCustomElementsUpgrade < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @registry = @win.custom_elements
  end

  # WPT: upgrading/Node-cloneNode.html, reactions/CustomElementRegistry.html

  def test_define_upgrades_existing_subtree
    @doc.body.inner_html = "<u-late id='x'></u-late>"
    klass = Class.new(Dommy::HTMLElement)
    @registry.define("u-late", klass)
    assert_kind_of(klass, @doc.get_element_by_id("x"))
  end

  def test_define_fires_connectedCallback_on_upgraded_nodes
    @doc.body.inner_html = "<u-c id='x'></u-c>"
    klass = Class.new(Dommy::HTMLElement) do
      attr_accessor(:connected_count)
      define_method(:connected_callback) { @connected_count = (@connected_count || 0) + 1 }
    end

    @registry.define("u-c", klass)
    assert_equal(1, @doc.get_element_by_id("x").connected_count)
  end

  def test_define_upgrades_nested_descendants
    @doc.body.inner_html = "<div><u-n id='a'></u-n><div><u-n id='b'></u-n></div></div>"
    klass = Class.new(Dommy::HTMLElement)
    @registry.define("u-n", klass)
    assert_kind_of(klass, @doc.get_element_by_id("a"))
    assert_kind_of(klass, @doc.get_element_by_id("b"))
  end

  def test_upgrade_explicit_call_walks_subtree
    @doc.body.inner_html = "<div id='root'><u-ex id='x'></u-ex></div>"
    klass = Class.new(Dommy::HTMLElement) do
      attr_accessor(:connected_count)
      define_method(:connected_callback) { @connected_count = (@connected_count || 0) + 1 }
    end

    @registry.define("u-ex", klass)
    el = @doc.get_element_by_id("x")
    # Already upgraded by define; upgrade(root) should not double-fire connected.
    before = el.connected_count
    @registry.upgrade(@doc.get_element_by_id("root"))
    assert_equal(before, el.connected_count)
  end

  def test_unregistered_hyphenated_name_remains_plain_element
    el = @doc.create_element("never-defined")
    assert_kind_of(Dommy::Element, el)
    refute_kind_of(Dommy::HTMLAnchorElement, el)
  end
end

class TestWPTCustomElementsCallbacks < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @registry = @win.custom_elements
  end

  # WPT: reactions/* — order semantics

  def test_connected_then_disconnected_order
    log = []
    klass = Class.new(Dommy::HTMLElement) do
      define_method(:connected_callback) { log << :connected }
      define_method(:disconnected_callback) { log << :disconnected }
    end

    @registry.define("o-1", klass)
    el = @doc.create_element("o-1")
    @doc.body.append(el)
    el.remove
    assert_equal([:connected, :disconnected], log)
  end

  def test_attribute_change_then_connect_order
    log = []
    klass = Class.new(Dommy::HTMLElement) do
      define_singleton_method(:observed_attributes) { ["data-v"] }
      define_method(:connected_callback) { log << :connected }
      define_method(:attribute_changed_callback) { |_, _, _| log << :attr }
    end

    @registry.define("o-2", klass)
    el = @doc.create_element("o-2")
    el.set_attribute("data-v", "1")
    @doc.body.append(el)
    assert_equal([:attr, :connected], log)
  end

  def test_callback_exception_is_swallowed
    klass = Class.new(Dommy::HTMLElement) do
      define_method(:connected_callback) { raise "boom" }
    end

    @registry.define("o-3", klass)
    el = @doc.create_element("o-3")
    # Must not propagate exception to caller (which would corrupt tree mutation).
    @doc.body.append(el)
    assert_equal("O-3", el.tag_name)
  end
end
