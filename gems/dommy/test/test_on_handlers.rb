# frozen_string_literal: true

require_relative "test_helper"

class TestOnHandlers < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<button id='b'>X</button>")
    @doc = @win.document
    @btn = @doc.get_element_by_id("b")
  end

  def test_onclick_setter_registers_listener
    seen = false
    @btn[:onclick] = proc { seen = true }
    @btn.click
    assert(seen)
  end

  def test_onclick_getter_returns_handler
    handler = proc { }
    @btn[:onclick] = handler
    assert_same(handler, @btn[:onclick])
  end

  def test_onclick_overwrite_removes_previous
    counts = [0, 0]
    @btn[:onclick] = proc { counts[0] += 1 }
    @btn[:onclick] = proc { counts[1] += 1 }
    @btn.click
    assert_equal(0, counts[0])
    assert_equal(1, counts[1])
  end

  def test_onclick_set_to_nil_removes
    fired = 0
    @btn[:onclick] = proc { fired += 1 }
    @btn.click
    @btn[:onclick] = nil
    @btn.click
    assert_equal(1, fired)
  end

  def test_onkeydown_handler
    seen = nil
    @btn[:onkeydown] = proc { |e| seen = e.__js_get__("key") }
    @btn.dispatch_event(Dommy::KeyboardEvent.new("keydown", "key" => "Enter"))
    assert_equal("Enter", seen)
  end

  def test_oninput_handler
    seen = false
    @btn[:oninput] = proc { seen = true }
    @btn.dispatch_event(Dommy::Event.new("input"))
    assert(seen)
  end
end
