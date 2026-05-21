# frozen_string_literal: true

require_relative "../test_helper"

class TestCookieJar < Minitest::Test
  def setup
    @jar = Dommy::Internal::CookieJar.new
  end

  def test_empty_jar_returns_empty_string
    assert_equal("", @jar.to_cookie_string)
  end

  def test_set_and_get_single_cookie
    @jar.set_cookie("name=alice")
    assert_equal("name=alice", @jar.to_cookie_string)
  end

  def test_multiple_cookies_joined_with_semicolon
    @jar.set_cookie("name=alice")
    @jar.set_cookie("session=abc123")
    assert_equal("name=alice; session=abc123", @jar.to_cookie_string)
  end

  def test_set_cookie_overwrites_existing_value
    @jar.set_cookie("name=alice")
    @jar.set_cookie("name=bob")
    assert_equal("name=bob", @jar.to_cookie_string)
  end

  def test_set_cookie_strips_attributes
    @jar.set_cookie("name=alice; Path=/; HttpOnly")
    assert_equal("name=alice", @jar.to_cookie_string)
  end

  def test_set_cookie_trims_whitespace
    @jar.set_cookie("  name = alice  ")
    assert_equal("name=alice", @jar.to_cookie_string)
  end

  def test_set_cookie_ignores_empty_value
    @jar.set_cookie("")
    @jar.set_cookie("   ")
    assert_equal("", @jar.to_cookie_string)
  end

  def test_set_cookie_with_no_equals_sign
    @jar.set_cookie("flag")
    assert_equal("flag=", @jar.to_cookie_string)
  end
end
