# frozen_string_literal: true

require_relative "test_helper"

class TestShadowEventComposition < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='outer'><div id='host'></div></div>")
    @doc = @win.document
    @outer = @doc.get_element_by_id("outer")
    @host = @doc.get_element_by_id("host")
    @sr = @host.attach_shadow({"mode" => "open"})
    @sr.inner_html = "<button id='btn'>X</button>"
    @btn = @sr.get_element_by_id("btn")
  end

  def test_non_composed_event_stops_at_shadow_boundary
    seen_host = false
    seen_outer = false
    @host.add_event_listener("click", proc { seen_host = true })
    @outer.add_event_listener("click", proc { seen_outer = true })

    ev = Dommy::Event.new("click", "bubbles" => true)
    @btn.dispatch_event(ev)

    refute(seen_host, "Host listener fired despite non-composed event")
    refute(seen_outer)
  end

  def test_composed_event_crosses_shadow_boundary
    seen_host = false
    seen_outer = false
    @host.add_event_listener("click", proc { seen_host = true })
    @outer.add_event_listener("click", proc { seen_outer = true })

    ev = Dommy::Event.new("click", "bubbles" => true, "composed" => true)
    @btn.dispatch_event(ev)

    assert(seen_host, "Host should receive composed event from shadow tree")
    assert(seen_outer, "Outer should receive composed event from shadow tree")
  end

  def test_composed_path_includes_host_when_composed
    captured = nil
    @host.add_event_listener("click", proc { |e| captured = e.__js_call__("composedPath", []) })

    ev = Dommy::Event.new("click", "bubbles" => true, "composed" => true)
    @btn.dispatch_event(ev)

    refute_nil(captured)
    # Path should include the button, host, outer, body chain.
    assert_includes(captured, @host)
    assert_includes(captured, @btn)
  end

  def test_composed_path_does_not_include_host_when_not_composed
    captured = nil
    # Listen on the button itself so we still get composedPath data.
    @btn.add_event_listener("click", proc { |e| captured = e.__js_call__("composedPath", []) })

    ev = Dommy::Event.new("click", "bubbles" => true)
    @btn.dispatch_event(ev)

    refute_nil(captured)
    refute_includes(captured, @host)
  end

  def test_stop_propagation_at_shadow_boundary
    seen_host = false
    @host.add_event_listener("click", proc { seen_host = true })

    @sr.add_event_listener("click", proc { |e| e.__js_call__("stopPropagation", []) })

    ev = Dommy::Event.new("click", "bubbles" => true, "composed" => true)
    @btn.dispatch_event(ev)
    refute(seen_host)
  end
end
