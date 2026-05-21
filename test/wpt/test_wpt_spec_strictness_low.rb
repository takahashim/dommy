# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived coverage for the low-priority strictness fixes:
#   - Custom element classes' `construct` hook runs once at instantiation
#   - `isConnected` walks across ShadowRoot boundaries
#   - HTMLInputElement value sanitization + ValidityState.bad_input
class TestWPTCustomElementConstruct < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @registry = @win.custom_elements
  end

  # WPT: custom-elements/upgrading/Node-cloneNode.html, microtasks-and-constructors.html

  def test_construct_runs_on_createElement
    seen = false
    klass = Class.new(Dommy::HTMLElement) do
      define_method(:construct) { seen = true }
    end

    @registry.define("c-1", klass)
    @doc.create_element("c-1")
    assert(seen)
  end

  def test_construct_runs_only_once_per_node
    count = 0
    klass = Class.new(Dommy::HTMLElement) do
      define_method(:construct) { count += 1 }
    end

    @registry.define("c-2", klass)
    el = @doc.create_element("c-2")
    @doc.body.append(el)
    el.set_attribute("data-x", "1")
    # Each subsequent get_element_by_id / wrap_node should re-use the
    # cached wrapper without re-running construct.
    @doc.get_element_by_id("c-2")
    assert_equal(1, count)
  end

  def test_construct_can_attach_shadow
    klass = Class.new(Dommy::HTMLElement) do
      define_method(:construct) do
        attach_shadow({"mode" => "open"}).inner_html = "<p>hi</p>"
      end
    end

    @registry.define("c-3", klass)
    el = @doc.create_element("c-3")
    refute_nil(el.shadow_root)
    assert_equal("<p>hi</p>", el.shadow_root.inner_html)
  end

  def test_construct_runs_on_upgrade_of_existing_nodes
    @doc.body.inner_html = "<c-4 id='x'></c-4>"
    seen = false
    klass = Class.new(Dommy::HTMLElement) do
      define_method(:construct) { seen = true }
    end

    @registry.define("c-4", klass)
    refute_nil(@doc.get_element_by_id("x"))
    assert(seen)
  end

  def test_construct_exception_is_swallowed
    klass = Class.new(Dommy::HTMLElement) do
      define_method(:construct) { raise "boom" }
    end

    @registry.define("c-5", klass)
    # Must not propagate.
    el = @doc.create_element("c-5")
    refute_nil(el)
  end
end

class TestWPTIsConnectedShadow < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
    @sr = @host.attach_shadow({"mode" => "open"})
  end

  # WPT: dom/nodes/Node-isConnected.html (shadow-tree paths)

  def test_descendant_of_connected_host_is_connected
    p = @doc.create_element("p")
    @sr.append_child(p)
    assert(p.is_connected?)
  end

  def test_descendant_of_detached_host_is_disconnected
    other_host = @doc.create_element("div")
    sr2 = other_host.attach_shadow({"mode" => "open"})
    p = @doc.create_element("p")
    sr2.append_child(p)
    refute(p.is_connected?)
  end

  def test_closed_shadow_descendant_still_connected
    closed_host = @doc.create_element("div")
    @doc.body.append(closed_host)
    sr = closed_host.attach_shadow({"mode" => "closed"})
    p = @doc.create_element("p")
    sr.append_child(p)
    assert(p.is_connected?)
  end

  def test_freshly_created_element_disconnected
    refute(@doc.create_element("p").is_connected?)
  end

  def test_appended_to_body_connected
    el = @doc.create_element("p")
    @doc.body.append(el)
    assert(el.is_connected?)
  end

  def test_removed_element_becomes_disconnected
    el = @doc.create_element("p")
    @doc.body.append(el)
    el.remove
    refute(el.is_connected?)
  end
end

class TestWPTInputSanitization < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def input(type, attrs = {})
    el = @doc.create_element("input")
    el.type = type
    attrs.each { |k, v| el.set_attribute(k.to_s, v.to_s) }
    el
  end

  # WPT: html/semantics/forms/input/input-value-sanitization.html

  def test_number_invalid_string_sanitizes_to_empty
    i = input("number")
    i.value = "abc"
    assert_equal("", i.value)
  end

  def test_number_valid_float_passes_through
    i = input("number")
    i.value = "3.14"
    assert_equal("3.14", i.value)
  end

  def test_number_negative_valid
    i = input("number")
    i.value = "-5"
    assert_equal("-5", i.value)
  end

  def test_email_trims_whitespace
    i = input("email")
    i.value = "  alice@x.test  "
    assert_equal("alice@x.test", i.value)
  end

  def test_email_multiple_trims_each
    i = input("email", multiple: "")
    i.value = "  a@x.test , b@x.test  "
    assert_equal("a@x.test,b@x.test", i.value)
  end

  def test_url_trims_whitespace
    i = input("url")
    i.value = "  https://x.test  "
    assert_equal("https://x.test", i.value)
  end

  def test_color_invalid_falls_back_to_black
    i = input("color")
    i.value = "not a color"
    assert_equal("#000000", i.value)
  end

  def test_color_lowercased
    i = input("color")
    i.value = "#FFAABB"
    assert_equal("#ffaabb", i.value)
  end

  def test_color_valid_passes_through
    i = input("color")
    i.value = "#abcdef"
    assert_equal("#abcdef", i.value)
  end

  def test_raw_value_preserved_after_sanitization
    i = input("number")
    i.value = "abc"
    assert_equal("abc", i.raw_value)
    assert_equal("", i.value)
  end
end

class TestWPTInputBadInput < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def input(type)
    el = @doc.create_element("input")
    el.type = type
    el
  end

  # WPT: html/semantics/forms/input/input-validation.html
  # (badInput flag of ValidityState)

  def test_number_non_numeric_sets_badInput
    i = input("number")
    i.value = "abc"
    assert(i.validity.bad_input)
  end

  def test_number_numeric_clears_badInput
    i = input("number")
    i.value = "1.5"
    refute(i.validity.bad_input)
  end

  def test_color_invalid_sets_badInput
    i = input("color")
    i.value = "purple"
    assert(i.validity.bad_input)
  end

  def test_color_valid_clears_badInput
    i = input("color")
    i.value = "#aabbcc"
    refute(i.validity.bad_input)
  end

  def test_text_never_bad_input
    i = input("text")
    i.value = "anything"
    refute(i.validity.bad_input)
  end

  def test_badInput_visible_via_validity
    i = input("number")
    i.value = "xyz"
    assert(i.validity.__js_get__("badInput"))
    refute(i.validity.__js_get__("valid"))
  end

  def test_empty_value_not_badInput
    i = input("number")
    i.value = ""
    refute(i.validity.bad_input)
  end
end
