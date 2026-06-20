# frozen_string_literal: true

require_relative "test_helper"

class TestCustomElementsRegistry < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @registry = @win.custom_elements
  end

  def test_window_has_custom_elements
    assert_kind_of(Dommy::CustomElementRegistry, @registry)
  end

  def test_define_rejects_unhyphenated_name
    assert_raises(Dommy::DOMException::SyntaxError) { @registry.define("nodash", Dommy::HTMLElement) }
  end

  # HTML reserves these hyphenated names (SVG/MathML), so they are not valid
  # custom element names even though they pass the hyphen check.
  def test_define_rejects_reserved_names
    %w[annotation-xml color-profile font-face font-face-src font-face-uri
       font-face-format font-face-name missing-glyph].each do |name|
      assert_raises(Dommy::DOMException::SyntaxError, "expected #{name} to be rejected") do
        @registry.define(name, Dommy::HTMLElement)
      end
    end
  end

  def test_define_allows_normal_hyphenated_name
    @registry.define("font-faces", Dommy::HTMLElement) # not reserved (plural)
    assert_equal Dommy::HTMLElement, @registry.get("font-faces")
  end

  # Per the spec's PotentialCustomElementName production, names may contain
  # ".", "_", digits, and a wide Unicode range after the first ASCII-lower char.
  def test_define_allows_spec_valid_pcen_names
    %w[my-button x-_y a-b.c emoji-😀].each do |name|
      @registry.define(name, Dommy::HTMLElement)
      assert_equal Dommy::HTMLElement, @registry.get(name), "expected #{name} to register"
    end
  end

  def test_define_rejects_uppercase_and_digit_start
    ["Foo-bar", "1-x", "-x", "no space-x"].each do |name|
      assert_raises(Dommy::DOMException::SyntaxError, "expected #{name} to be rejected") do
        @registry.define(name, Dommy::HTMLElement)
      end
    end
  end

  def test_define_rejects_double_registration
    klass = Class.new(Dommy::HTMLElement)
    @registry.define("my-thing", klass)
    assert_raises(Dommy::DOMException::NotSupportedError) { @registry.define("my-thing", klass) }
  end

  def test_get_returns_registered_class
    klass = Class.new(Dommy::HTMLElement)
    @registry.define("my-widget", klass)
    assert_equal(klass, @registry.get("my-widget"))
  end

  def test_get_returns_nil_for_unknown
    assert_nil(@registry.get("not-defined"))
  end

  def test_when_defined_resolves_after_define
    klass = Class.new(Dommy::HTMLElement)
    received = nil
    promise = @registry.when_defined("late-arrival")
    promise.__js_call__("then", [proc { |k| received = k }])

    @registry.define("late-arrival", klass)
    @win.scheduler.drain_microtasks

    assert_equal(klass, received)
  end

  def test_when_defined_already_defined_resolves_immediately
    klass = Class.new(Dommy::HTMLElement)
    @registry.define("early-bird", klass)

    received = nil
    promise = @registry.when_defined("early-bird")
    promise.__js_call__("then", [proc { |k| received = k }])
    @win.scheduler.drain_microtasks

    assert_equal(klass, received)
  end
end

class TestCustomElementLifecycle < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @registry = @win.custom_elements
  end

  def make_widget_class(observed: [])
    Class.new(Dommy::HTMLElement) do
      define_singleton_method(:observed_attributes) { observed }
      attr_accessor(:connected_count, :disconnected_count, :attribute_changes)
      define_method(:connected_callback) { @connected_count = (@connected_count || 0) + 1 }
      define_method(:disconnected_callback) { @disconnected_count = (@disconnected_count || 0) + 1 }
      define_method(:attribute_changed_callback) do |name, old, new|
        @attribute_changes ||= []
        @attribute_changes << [name, old, new]
      end
    end
  end

  def test_class_dispatch_for_registered_tag
    klass = make_widget_class
    @registry.define("my-card", klass)
    el = @doc.create_element("my-card")
    assert_kind_of(klass, el)
  end

  def test_unregistered_hyphenated_tag_falls_back_to_element
    el = @doc.create_element("unknown-tag")
    assert_kind_of(Dommy::Element, el)
    refute_kind_of(Dommy::HTMLAnchorElement, el)
  end

  def test_connected_callback_fires_on_append
    klass = make_widget_class
    @registry.define("my-card", klass)
    el = @doc.create_element("my-card")
    @doc.body.append(el)
    assert_equal(1, el.connected_count)
  end

  def test_disconnected_callback_fires_on_remove
    klass = make_widget_class
    @registry.define("my-card", klass)
    el = @doc.create_element("my-card")
    @doc.body.append(el)
    el.remove
    assert_equal(1, el.disconnected_count)
  end

  def test_attribute_changed_only_for_observed
    klass = make_widget_class(observed: ["data-state"])
    @registry.define("my-toggle", klass)
    el = @doc.create_element("my-toggle")
    @doc.body.append(el)
    el.set_attribute("data-state", "on")
    el.set_attribute("data-ignored", "x")
    refute_nil(el.attribute_changes)
    assert_equal([["data-state", nil, "on"]], el.attribute_changes)
  end

  def test_attribute_changed_includes_old_value
    klass = make_widget_class(observed: ["data-x"])
    @registry.define("my-x", klass)
    el = @doc.create_element("my-x")
    el.set_attribute("data-x", "first")
    @doc.body.append(el)
    el.set_attribute("data-x", "second")
    last = el.attribute_changes.last
    assert_equal(["data-x", "first", "second"], last)
  end

  def test_callbacks_swallow_exceptions
    klass = Class.new(Dommy::HTMLElement) do
      define_method(:connected_callback) { raise "boom" }
    end

    @registry.define("bad-widget", klass)
    el = @doc.create_element("bad-widget")
    # Should not propagate the exception.
    @doc.body.append(el)
    assert(true)
  end
end

class TestCustomElementUpgrade < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @registry = @win.custom_elements
  end

  def test_define_after_parse_upgrades_existing_nodes
    @doc.body.inner_html = "<my-late id='x'></my-late>"
    klass = Class.new(Dommy::HTMLElement) do
      attr_accessor(:connected_count)
      define_method(:connected_callback) { @connected_count = (@connected_count || 0) + 1 }
    end

    @registry.define("my-late", klass)

    el = @doc.get_element_by_id("x")
    assert_kind_of(klass, el)
    assert_equal(1, el.connected_count)
  end

  def test_upgrade_walks_subtree
    klass = Class.new(Dommy::HTMLElement) do
      attr_accessor(:connected_count)
      define_method(:connected_callback) { @connected_count = (@connected_count || 0) + 1 }
    end

    @doc.body.inner_html = "<div><my-x id='a'></my-x><div><my-x id='b'></my-x></div></div>"
    @registry.define("my-x", klass)

    a = @doc.get_element_by_id("a")
    b = @doc.get_element_by_id("b")
    assert_kind_of(klass, a)
    assert_kind_of(klass, b)
    assert_equal(1, a.connected_count)
    assert_equal(1, b.connected_count)
  end

  # A page's `customElements.define(name, classExpr)` registers a JS constructor
  # (a HostCallback), not a Ruby class. Wrapping such an element — on the
  # define-time upgrade and on a later query — must fall back to the built-in
  # element (the SSR'd content still renders) rather than `.new`-ing the JS
  # object, which used to crash whole-tree walks (e.g. github's web components).
  def test_js_constructor_definition_falls_back_without_crashing
    @doc.body.inner_html = "<x-widget>hello world</x-widget>"
    js_constructor = Object.new # stand-in for a Dommy::Js::HostCallback
    @registry.define("x-widget", js_constructor) # upgrade_existing must not crash

    el = @doc.query_selector("x-widget") # wrapping during a query must not crash
    refute_nil el
    assert_kind_of Dommy::Element, el
    refute_kind_of Dommy::Js::HostCallback, el if defined?(Dommy::Js::HostCallback)
    assert_equal "hello world", el.text_content
  end
end
