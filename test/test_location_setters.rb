# frozen_string_literal: true

require_relative "test_helper"

class TestLocationSetters < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @loc = @win.location
  end

  def test_host_setter
    @loc.__js_set__("host", "example.com:8080")
    assert_equal("example.com", @loc.__js_get__("hostname"))
    assert_equal("8080", @loc.__js_get__("port"))
  end

  def test_hostname_setter
    @loc.__js_set__("hostname", "foo.test")
    assert_equal("foo.test", @loc.__js_get__("hostname"))
  end

  def test_port_setter
    @loc.__js_set__("port", "9000")
    assert_equal("9000", @loc.__js_get__("port"))
  end

  def test_protocol_setter
    @loc.__js_set__("protocol", "https:")
    assert_equal("https:", @loc.__js_get__("protocol"))
  end

  def test_assign_sets_url
    @loc.__js_call__("assign", ["/new-path?x=1"])
    assert_equal("/new-path", @loc.__js_get__("pathname"))
  end

  def test_replace_sets_url
    @loc.__js_call__("replace", ["/replaced"])
    assert_equal("/replaced", @loc.__js_get__("pathname"))
  end

  def test_reload_noop
    assert_nil(@loc.__js_call__("reload", []))
  end
end
