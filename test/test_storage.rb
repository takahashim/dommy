# frozen_string_literal: true

require_relative "test_helper"

class TestStorage < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @storage = @win.__js_get__("localStorage")
  end

  def test_get_set_item
    @storage.__js_call__("setItem", ["k", "v"])
    assert_equal("v", @storage.__js_call__("getItem", ["k"]))
  end

  def test_set_coerces_to_string
    @storage.__js_call__("setItem", ["k", 42])
    assert_equal("42", @storage.__js_call__("getItem", ["k"]))
  end

  def test_remove_item
    @storage.__js_call__("setItem", ["k", "v"])
    @storage.__js_call__("removeItem", ["k"])
    assert_nil(@storage.__js_call__("getItem", ["k"]))
  end

  def test_clear
    @storage.__js_call__("setItem", ["a", "1"])
    @storage.__js_call__("setItem", ["b", "2"])
    @storage.__js_call__("clear", [])
    assert_equal(0, @storage.__js_get__("length"))
  end

  def test_length
    @storage.__js_call__("setItem", ["a", "1"])
    @storage.__js_call__("setItem", ["b", "2"])
    assert_equal(2, @storage.__js_get__("length"))
  end

  def test_session_storage_is_independent_of_local
    @storage.__js_call__("setItem", ["k", "local"])
    sess = @win.__js_get__("sessionStorage")
    assert_nil(sess.__js_call__("getItem", ["k"]))
  end
end
