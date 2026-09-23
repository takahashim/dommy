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

# A Location whose browsing context is gone. HTML starts every setter and every
# navigation with "if this's relevant Document is null, then return", so a page
# holding a removed frame's location holds something readable and deaf.
class TestLocationWithoutBrowsingContext < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<body></body>")
    @doc = @win.document
    @frame = @doc.create_element("iframe")
    @doc.body.append_child(@frame)
    @loc = @frame.content_document.default_view.location
    @frame.remove
  end

  def test_setters_do_nothing
    @loc.__js_set__("href", "https://example.com/")
    @loc.__js_set__("hash", "x")
    @loc.__js_set__("protocol", "https")

    assert_equal("about:blank", @loc.__js_get__("href"))
  end

  def test_assign_and_replace_do_nothing
    @loc.__js_call__("assign", ["https://example.com/"])
    @loc.__js_call__("replace", ["https://example.com/"])

    assert_equal("about:blank", @loc.__js_get__("href"))
  end

  # A URL the parser rejects does not throw either: the setter returned before
  # it ever looked at the string.
  def test_an_invalid_url_does_not_raise
    @loc.__js_set__("href", "http://test:test/")

    assert_equal("about:blank", @loc.__js_get__("href"))
  end

  def test_origin_is_opaque
    assert_equal("null", @loc.__js_get__("origin"))
  end

  def test_ancestor_origins_is_empty
    assert_equal(0, @loc.__js_get__("ancestorOrigins").length)
  end

  # While the frame is still in the tree, the same location is live, and lists
  # the origin it is nested in.
  def test_a_frame_still_in_the_tree_is_live
    doc = make_window("<body></body>").document
    frame = doc.create_element("iframe")
    doc.body.append_child(frame)
    loc = frame.content_document.default_view.location

    loc.__js_set__("hash", "x")

    assert_equal("#x", loc.__js_get__("hash"))
    assert_equal(["http://localhost"], loc.__js_get__("ancestorOrigins").to_a)
    assert_same(loc.__js_get__("ancestorOrigins"), loc.__js_get__("ancestorOrigins"))
  end
end
