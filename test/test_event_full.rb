# frozen_string_literal: true

require_relative "test_helper"

# Round out Event coverage to match happy-dom's full set.
class TestEventFull < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='outer'><span id='inner'>x</span></div>")
    @doc = @win.document
    @outer = @doc.get_element_by_id("outer")
    @inner = @doc.get_element_by_id("inner")
  end

  def test_type_accessor
    ev = Dommy::Event.new("foo")
    assert_equal("foo", ev.__js_get__("type"))
  end

  def test_bubbles_default_false
    ev = Dommy::Event.new("foo")
    assert_equal(false, ev.__js_get__("bubbles"))
  end

  def test_bubbles_init_true
    ev = Dommy::Event.new("foo", "bubbles" => true)
    assert_equal(true, ev.__js_get__("bubbles"))
  end

  def test_cancelable_default_false
    ev = Dommy::Event.new("foo")
    assert_equal(false, ev.__js_get__("cancelable"))
  end

  def test_cancelable_init_true
    ev = Dommy::Event.new("foo", "cancelable" => true)
    assert_equal(true, ev.__js_get__("cancelable"))
  end

  def test_default_prevented_starts_false
    ev = Dommy::Event.new("foo")
    assert_equal(false, ev.__js_get__("defaultPrevented"))
  end

  def test_prevent_default_on_non_cancelable_is_noop
    ev = Dommy::Event.new("foo", "cancelable" => false)
    ev.__js_call__("preventDefault", [])
    assert_equal(false, ev.__js_get__("defaultPrevented"))
  end

  def test_prevent_default_on_cancelable_flips_flag
    ev = Dommy::Event.new("foo", "cancelable" => true)
    ev.__js_call__("preventDefault", [])
    assert_equal(true, ev.__js_get__("defaultPrevented"))
  end

  def test_init_event_resets_flags
    ev = Dommy::Event.new("foo", "cancelable" => true)
    ev.__js_call__("preventDefault", [])
    ev.__js_call__("initEvent", ["bar", true, true])
    assert_equal("bar", ev.__js_get__("type"))
    assert_equal(true, ev.__js_get__("bubbles"))
    assert_equal(true, ev.__js_get__("cancelable"))
    assert_equal(false, ev.__js_get__("defaultPrevented"))
  end

  def test_stop_immediate_propagation_blocks_subsequent_listeners
    seen = []
    @btn = @inner
    @btn.on("click") { |e|
      seen << :first
      e.__js_call__("stopImmediatePropagation", [])
    }
    @btn.on("click") { seen << :second }
    @btn.click
    assert_equal([:first], seen)
  end

  def test_target_after_dispatch
    captured = nil
    @inner.on("click") { |e| captured = e.__js_get__("target") }
    @inner.click
    assert_same(@inner, captured)
  end

  def test_current_target_changes_during_bubbling
    targets = []
    @inner.on("click") { |e| targets << e.__js_get__("currentTarget") }
    @outer.on("click") { |e| targets << e.__js_get__("currentTarget") }
    @inner.click
    assert_equal([@inner, @outer], targets)
  end

  def test_composed_path_on_load_event_excludes_window
    # ensures path is recorded
    @inner.add_event_listener("load", proc { })
    ev = Dommy::Event.new("load", "bubbles" => true)
    captured = nil
    @inner.on("load") { |e| captured = e.__js_call__("composedPath", []) }
    @inner.dispatch_event(ev)
    refute_nil(captured)
    refute_includes(captured, @win)
  end
end
