# frozen_string_literal: true

require_relative "test_helper"

# The non-node EventTargets answer the event handler IDL attributes their
# interfaces declare (event_handler_tables.rb, generated from the IDL) through
# EventTarget's handler map — and nothing else.
class TestEventHandlerTargets < Minitest::Test
  include DommyTestHelper

  def fire(target, type)
    target.dispatch_event(Dommy::Event.new(type))
  end

  def test_declared_handlers_fire_and_read_back
    win = make_window
    targets = {
      Dommy::XMLHttpRequest.new(win) => %w[onreadystatechange onload ontimeout],
      Dommy::XMLHttpRequest.new(win).upload => %w[onprogress onloadend],
      Dommy::FileReader.new(win) => %w[onload onerror],
      Dommy::MessageChannel.new(win).port1 => %w[onmessageerror onclose],
      Dommy::BroadcastChannel.new(win, "c") => %w[onmessage onmessageerror],
      Dommy::AbortController.new.signal => %w[onabort],
      Dommy::MediaQueryList.new(win, "all") => %w[onchange]
    }
    targets.each do |target, names|
      names.each do |name|
        assert_nil(target.__js_get__(name), "#{target.class}##{name} starts null")
        fired = []
        handler = proc { |_e| fired << name }
        assert_nil(target.__js_set__(name, handler))
        assert_same(handler, target.__js_get__(name))
        fire(target, name.delete_prefix("on"))
        assert_equal([name], fired, "#{target.class}##{name}")
      end
    end
  end

  def test_undeclared_names_are_not_handlers
    win = make_window
    [Dommy::XMLHttpRequest.new(win), Dommy::XMLHttpRequest.new(win).upload,
     Dommy::MessageChannel.new(win).port1, Dommy::AbortController.new.signal].each do |target|
      assert_same(Dommy::Bridge::ABSENT, target.__js_get__("onfoo"))
      assert_same(Dommy::Bridge::UNHANDLED, target.__js_set__("onfoo", proc {}))
    end
  end

  def test_a_non_object_value_is_null
    xhr = Dommy::XMLHttpRequest.new(make_window)
    xhr.__js_set__("onload", "alert(1)")
    assert_nil(xhr.__js_get__("onload"))
  end

  def test_setting_port_onmessage_starts_the_port
    win = make_window
    mc = Dommy::MessageChannel.new(win)
    got = []
    mc.port1.post_message("x")
    mc.port2.__js_set__("onmessage", proc { |e| got << e.data })
    win.scheduler.advance_time(0)
    assert_equal(["x"], got)
  end
end
