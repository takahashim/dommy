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

  # Upgrading replays each attribute in list order with its local name, a
  # null old value, its value and its namespace — a namespaced one too, and
  # not the first attribute that merely shares its qualified name.
  def test_upgrade_replays_each_attribute_with_its_namespace
    @doc.body.inner_html = "<my-replay id='r'></my-replay>"
    pending = @doc.get_element_by_id("r")
    pending.set_attribute_ns("urn:x", "a", "ns")
    pending.set_attribute_ns(nil, "a", "plain")
    klass = Class.new(Dommy::HTMLElement) do
      define_singleton_method(:observed_attributes) { %w[a] }
      attr_reader(:changes)
      define_method(:attribute_changed_callback) do |name, old, new, namespace|
        (@changes ||= []) << [name, old, new, namespace]
      end
    end

    @registry.define("my-replay", klass)

    assert_equal([["a", nil, "ns", "urn:x"], ["a", nil, "plain", nil]], @doc.get_element_by_id("r").changes)
  end

  # observedAttributes is matched against the local name exactly.
  def test_observed_attributes_match_the_local_name_exactly
    klass = Class.new(Dommy::HTMLElement) do
      define_singleton_method(:observed_attributes) { %w[fooBar] }
      attr_reader(:changes)
      define_method(:attribute_changed_callback) { |name, _old, _new| (@changes ||= []) << name }
    end
    @registry.define("my-exact", klass)
    el = @doc.create_element("my-exact")

    el.set_attribute_ns(nil, "fooBar", "1")
    el.set_attribute_ns(nil, "foobar", "2")
    assert_equal ["fooBar"], el.changes
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

  # define()'s first check (IsConstructor): what is not a class is a
  # TypeError, and the elements in the document are left as they were.
  def test_define_rejects_a_non_class
    @doc.body.inner_html = "<x-widget>hello world</x-widget>"
    assert_raises(Dommy::Bridge::TypeError) { @registry.define("x-widget", Object.new) }

    el = @doc.query_selector("x-widget")
    assert_instance_of Dommy::HTMLElement, el
    assert_equal "hello world", el.text_content
    assert_nil @registry.get("x-widget")
  end
end

# A custom element's own class is no interface: it reports the interface it
# derives from, so `Object.prototype.toString` says HTMLElement and the
# prototype members' receiver checks accept it.
class TestCustomElementInterfaceChain < Minitest::Test
  include DommyTestHelper

  def test_anonymous_custom_element_class_reports_html_element
    win = make_window
    win.custom_elements.define("my-chain", Class.new(Dommy::HTMLElement))
    el = win.document.create_element("my-chain")
    assert_equal %w[HTMLElement Element Node EventTarget], Dommy::Js::DomInterfaces.chain_for(el)
  end
end

# HTML §4.13.6 custom element reactions, as Ruby code driving the DOM sees
# them: an operation's reactions run when it returns, in the order they were
# enqueued, element by element.
class TestCustomElementReactions < Minitest::Test
  include DommyTestHelper

  LOG = []

  class Logged < Dommy::HTMLElement
    def self.observed_attributes = %w[a]
    def construct = LOG << [:construct, local_name]
    def connected_callback = LOG << [:connected, get_attribute("id")]
    def disconnected_callback = LOG << [:disconnected, get_attribute("id")]
    def adopted_callback(old_doc, new_doc) = LOG << [:adopted, old_doc.class, new_doc.class]
    def attribute_changed_callback(name, old, new) = LOG << [:attr, name, old, new]
  end

  def setup
    LOG.clear
    @win = make_window
    @doc = @win.document
    @win.custom_elements.define("x-logged", Logged)
  end

  # innerHTML parses (an upgrade reaction) and inserts (a second, which bails):
  # the element is constructed and connected once.
  def test_inner_html_on_a_connected_element_upgrades_and_connects_once
    @doc.body.inner_html = "<x-logged id=one a=1></x-logged>"
    assert_equal [[:construct, "x-logged"], [:attr, "a", nil, "1"], [:connected, "one"]], LOG
    assert_instance_of Logged, @doc.get_element_by_id("one")
  end

  # The fragment parser upgrades what it creates even into a detached element.
  def test_inner_html_on_a_detached_element_upgrades_without_connecting
    div = @doc.create_element("div")
    div.inner_html = "<x-logged id=two></x-logged>"
    assert_equal [[:construct, "x-logged"]], LOG
    assert_instance_of Logged, div.first_element_child
  end

  def test_clone_node_upgrades_the_copy
    el = @doc.create_element("x-logged")
    el.set_attribute("a", "1")
    LOG.clear
    copy = el.clone_node(false)
    assert_instance_of Logged, copy
    assert_equal [[:construct, "x-logged"], [:attr, "a", nil, "1"]], LOG
  end

  # DOM adopt: a custom element moved to another document gets
  # adoptedCallback(old, new) between its disconnected and connected
  # callbacks.
  def test_moving_to_another_document_runs_adopted_callback
    el = @doc.create_element("x-logged")
    el.id = "m"
    @doc.body.append_child(el)
    other = @doc.implementation.create_html_document
    LOG.clear
    other.body.append_child(el)
    assert_equal [[:disconnected, "m"], [:adopted, Dommy::Document, Dommy::Document], [:connected, "m"]], LOG
  end

  # Only an element that becomes connected — shadow-including — is
  # connected: a detached host's shadow tree is not.
  def test_inserting_into_a_detached_shadow_tree_does_not_connect
    host = @doc.create_element("div")
    root = host.attach_shadow("mode" => "open")
    el = @doc.create_element("x-logged")
    LOG.clear
    root.append_child(el)
    assert_empty LOG
    @doc.body.append_child(host)
    assert_equal [[:connected, nil]], LOG
  end

  # A custom element only: an undefined element gets no callbacks, and is
  # upgraded when it is connected.
  def test_an_undefined_element_is_upgraded_when_connected
    early = Dommy::Window.new
    el = early.document.create_element("x-late")
    el.set_attribute("a", "1")
    early.document.body.append_child(el)
    early.custom_elements.define("x-late", Logged)
    assert_equal [[:construct, "x-late"], [:attr, "a", nil, "1"], [:connected, nil]], LOG
  end
end

# An upgrade makes the element `:defined`, a selector-observable state like
# checkedness: a computed style or a cached query that looked at it is
# recomputed.
class TestCustomElementUpgradeIsObservable < Minitest::Test
  include DommyTestHelper

  class Plain < Dommy::HTMLElement; end

  def setup
    @win = make_window('<style>x-late:defined .child { color: red }</style><x-late><p class="child" id="c">x</p></x-late>')
    @doc = @win.document
  end

  def color_of_child
    Dommy::Internal::CSS::Cascade.computed_style(@doc.get_element_by_id("c"))["color"]
  end

  def test_a_rule_on_defined_reaches_the_descendants_after_the_upgrade
    refute_equal "rgb(255, 0, 0)", color_of_child
    @win.custom_elements.define("x-late", Plain)
    assert_equal "rgb(255, 0, 0)", color_of_child
  end

  def test_a_cached_query_on_defined_sees_the_upgrade
    assert_empty @doc.query_selector_all("x-late:defined")
    @win.custom_elements.define("x-late", Plain)
    assert_equal 1, @doc.query_selector_all("x-late:defined").length
  end
end

# DOM "create an element" with the synchronous custom elements flag: a
# constructor that throws is reported, and the element is an
# HTMLUnknownElement whose custom element state is "failed".
class TestCustomElementSynchronousConstruction < Minitest::Test
  include DommyTestHelper

  class Throws < Dommy::HTMLElement
    def construct = raise("boom")
  end

  def test_a_throwing_constructor_makes_a_failed_unknown_element
    win = make_window
    reported = []
    win.define_singleton_method(:__internal_report_exception__) { |*args| reported << args }
    win.custom_elements.define("x-throws", Throws)
    el = win.document.create_element("x-throws")
    assert_instance_of Dommy::HTMLUnknownElement, el
    assert_equal "failed", el.__internal_custom_element_state__
    assert_equal "x-throws", el.local_name
    refute_empty reported
    refute Dommy::Internal::ElementState.defined_element?(el)
  end
end

# ElementInternals (HTML §4.13.7) for a Ruby-defined custom element: custom
# states matched by `:state()`, and a form-associated element's submission
# value, validity and form callbacks.
class TestElementInternals < Minitest::Test
  include DommyTestHelper

  class Plain < Dommy::HTMLElement; end

  class Control < Dommy::HTMLElement
    def self.form_associated = true
    attr_reader :history

    def construct
      @history = []
      @internals = attach_internals
    end

    def internals = @internals
    def form_associated_callback(form) = @history << [:form, form&.id]
    def form_reset_callback = @history << [:reset]
    def form_disabled_callback(disabled) = @history << [:disabled, disabled]
  end

  def setup
    @win = make_window
    @doc = @win.document
    @win.custom_elements.define("x-plain", Plain)
    @win.custom_elements.define("x-control", Control)
  end

  def test_attach_internals_once_and_only_for_custom_elements
    el = @doc.create_element("x-plain")
    assert_instance_of Dommy::ElementInternals, el.attach_internals
    assert_raises(Dommy::DOMException::NotSupportedError) { el.attach_internals }
    assert_raises(Dommy::DOMException::NotSupportedError) { @doc.create_element("div").attach_internals }
    assert_raises(Dommy::DOMException::NotSupportedError) { @doc.create_element("x-undefined").attach_internals }
  end

  def test_custom_states_match_the_state_pseudo_class
    el = @doc.create_element("x-plain")
    @doc.body.append_child(el)
    internals = el.attach_internals
    assert_nil @doc.query_selector("x-plain:state(open)")
    internals.__internal_set_states__(["open"])
    assert_same el, @doc.query_selector("x-plain:state(open)")
    assert_raises(Dommy::DOMException::SyntaxError) { @doc.query_selector(":state(16px)") }
  end

  def test_form_value_validity_and_callbacks
    @doc.body.inner_html = "<form id=f><x-control name=c></x-control></form>"
    form = @doc.get_element_by_id("f")
    control = @doc.query_selector("x-control")
    assert_equal [[:form, "f"]], control.history
    control.internals.set_form_value("v")
    assert_equal [%w[c v]], Dommy::FormData.new(form).entries
    assert_includes form.elements.to_a, control

    control.internals.set_validity({ "valueMissing" => true }, "fill me")
    refute form.check_validity
    assert_equal "fill me", control.internals.validation_message

    form.reset
    control.set_attribute("disabled", "")
    assert_equal [[:form, "f"], [:reset], [:disabled, true]], control.history
    assert_empty Dommy::FormData.new(form).entries
    assert_raises(Dommy::DOMException::NotSupportedError) { @doc.create_element("x-plain").attach_internals.form }
  end
end
