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

  def test_href_absolute_url_updates_origin
    @loc.__js_set__("href", "https://example.com:3000/a?b=1#c")
    assert_equal("https://example.com:3000", @loc.__js_get__("origin"))
    assert_equal("/a", @loc.__js_get__("pathname"))
    assert_equal("?b=1", @loc.__js_get__("search"))
    assert_equal("#c", @loc.__js_get__("hash"))
  end

  def test_href_relative_url_keeps_origin
    @loc.__js_set__("href", "/only/path")
    assert_equal("http://localhost", @loc.__js_get__("origin"))
    assert_equal("/only/path", @loc.__js_get__("pathname"))
  end

  def test_replace_sets_url
    @loc.__js_call__("replace", ["/replaced"])
    assert_equal("/replaced", @loc.__js_get__("pathname"))
  end

  def test_reload_noop
    assert_nil(@loc.__js_call__("reload", []))
  end
end
