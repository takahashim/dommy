# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for URL.username / URL.password.
# WPT: url/url-constructor.any.js (userinfo cases),
#      url/url-setters.any.js (username / password setters).
# Spec: https://url.spec.whatwg.org/#url-class
#
# Complements test/test_url.rb (which exercises pathname/search/hash/
# port/IDN setters). Existing tests do not exercise username/password,
# so this file fills that gap.
class TestWPTURLUserinfoParsing < Minitest::Test
  def test_parses_username_and_password
    url = Dommy::URL.new("https://alice:secret@example.test/path")
    assert_equal("alice", url.username)
    assert_equal("secret", url.password)
    assert_equal("example.test", url.host)
  end

  def test_parses_username_only
    # No `:password` segment — password is the empty string.
    url = Dommy::URL.new("https://alice@example.test/")
    assert_equal("alice", url.username)
    assert_equal("", url.password)
  end

  def test_no_userinfo_yields_empty_strings
    url = Dommy::URL.new("https://example.test/")
    assert_equal("", url.username)
    assert_equal("", url.password)
  end

  def test_href_round_trips_userinfo
    url = Dommy::URL.new("https://alice:secret@example.test/")
    assert_equal("https://alice:secret@example.test/", url.href)
  end
end

class TestWPTURLUserinfoSetters < Minitest::Test
  def setup
    @url = Dommy::URL.new("https://example.test/")
  end

  def test_username_setter_writes_value
    @url.username = "bob"
    assert_equal("bob", @url.username)
    assert_equal("https://bob@example.test/", @url.href)
  end

  def test_password_setter_writes_value
    # password requires a username for the authority `user:pass@host`
    # form to be valid; without one, browsers still encode it but the
    # serialization is implementation-defined. Dommy backs onto Ruby
    # URI which requires a non-nil user when password is set, so we
    # exercise the with-username path.
    @url.username = "bob"
    @url.password = "secret"
    assert_equal("secret", @url.password)
    assert_equal("https://bob:secret@example.test/", @url.href)
  end

  def test_username_setter_empty_string_clears
    url = Dommy::URL.new("https://alice:secret@example.test/")
    url.username = ""
    # Clearing username drops the entire userinfo segment in the
    # current backend (Ruby URI requires user to be non-nil when
    # password is set).
    refute(url.href.include?("@"))
  end

  def test_password_setter_empty_string_clears_password
    url = Dommy::URL.new("https://alice:secret@example.test/")
    url.password = ""
    assert_equal("", url.password)
    assert_equal("https://alice@example.test/", url.href)
  end
end

class TestWPTURLUserinfoOrigin < Minitest::Test
  # WHATWG URL §origin — the tuple origin is `(scheme, host, port,
  # null)`. Userinfo is *not* part of the origin.

  def test_origin_excludes_userinfo
    url = Dommy::URL.new("https://alice:secret@example.test/")
    assert_equal("https://example.test", url.origin)
  end

  def test_origin_excludes_userinfo_with_non_default_port
    url = Dommy::URL.new("https://alice:secret@example.test:8443/")
    assert_equal("https://example.test:8443", url.origin)
  end
end

class TestWPTURLUserinfoJSBridge < Minitest::Test
  def setup
    @url = Dommy::URL.new("https://example.test/")
  end

  def test_js_bridge_get_username
    @url.username = "bob"
    assert_equal("bob", @url.__js_get__("username"))
  end

  def test_js_bridge_get_password
    @url.username = "bob"
    @url.password = "secret"
    assert_equal("secret", @url.__js_get__("password"))
  end

  def test_js_bridge_set_username
    @url.__js_set__("username", "bob")
    assert_equal("bob", @url.username)
  end

  def test_js_bridge_set_password
    @url.__js_set__("username", "bob")
    @url.__js_set__("password", "secret")
    assert_equal("secret", @url.password)
  end
end
