# frozen_string_literal: true

require_relative "test_helper"

# `__js_get__` returns the ABSENT sentinel for a GENUINELY-absent property, so it
# marshals to JS `undefined` (value) AND the proxy reports `"x" in obj` false —
# distinct from a present property whose value is nil (JS null) or UNDEFINED.
class TestAbsentProperty < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id=\"x\"></div>")
    @el = @win.document.get_element_by_id("x")
  end

  def test_unknown_properties_are_absent_across_the_dom_surface
    assert_equal Dommy::Bridge::ABSENT, @win.__js_get__("Vue")
    assert_equal Dommy::Bridge::ABSENT, @el.__js_get__("totallyUnknownProp")
    assert_equal Dommy::Bridge::ABSENT, @win.document.__js_get__("nopeNope")
    assert_equal Dommy::Bridge::ABSENT, @win.navigator.__js_get__("bogusApi")
  end

  def test_present_but_null_stays_nil
    # An empty element's firstChild is present-but-null (JS null), NOT absent.
    assert_nil @el.__js_get__("firstChild")
  end

  def test_explicitly_set_window_global_wins_over_absent
    @win.__js_set__("custom", 7)
    assert_equal 7, @win.__js_get__("custom")
  end

  def test_absent_marshals_to_a_distinct_wire_tag
    bridge = Dommy::Js::HostBridge.new(@win) rescue nil
    skip "no marshaller available" unless bridge.respond_to?(:marshaller) || defined?(Dommy::Js::Marshaller)
    m = (bridge && bridge.respond_to?(:marshaller) ? bridge.marshaller : Dommy::Js::Marshaller.new(nil))
    assert_equal({Dommy::Js::WireTags::ABSENT => true}, m.wrap(Dommy::Bridge::ABSENT))
    assert_equal "undefined", Dommy::Bridge::ABSENT.to_s
  end
end
