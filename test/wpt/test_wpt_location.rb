# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived tests for Location not covered by test/test_location_*.rb.
# Existing files exercise individual getter/setter pairs; this file
# fills small gaps: toString(), protocol setter trailing-colon
# normalization, search/hash empty-string clearing, and the
# assign-vs-replace distinction in History.length.
#
# WPT: html/browsers/the-window-object/location-stringifier.html,
#      html/browsers/the-window-object/location-protocol.html,
#      html/browsers/the-window-object/location-assign-replace.html
# Spec: https://html.spec.whatwg.org/multipage/history.html#the-location-interface

class TestWPTLocationToString < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @loc = @win.location
  end

  def test_to_string_returns_href
    # Per spec, the stringifier returns the same string as `href`.
    assert_equal(@loc.__js_get__("href"), @loc.__js_call__("toString", []))
  end
end

class TestWPTLocationProtocolNormalization < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @loc = @win.location
  end

  def test_protocol_setter_appends_trailing_colon
    @loc.__js_set__("protocol", "ftp")
    assert_equal("ftp:", @loc.__js_get__("protocol"))
  end

  def test_protocol_setter_accepts_already_normalized_form
    @loc.__js_set__("protocol", "https:")
    assert_equal("https:", @loc.__js_get__("protocol"))
  end
end

class TestWPTLocationEmptyClear < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @loc = @win.location
  end

  def test_search_empty_string_clears
    @loc.__js_set__("search", "?a=1")
    assert_equal("?a=1", @loc.__js_get__("search"))
    @loc.__js_set__("search", "")
    assert_equal("", @loc.__js_get__("search"))
  end

  def test_hash_empty_string_clears
    @loc.__js_set__("hash", "#section")
    assert_equal("#section", @loc.__js_get__("hash"))
    @loc.__js_set__("hash", "")
    assert_equal("", @loc.__js_get__("hash"))
  end
end

class TestWPTLocationNavigationMethods < Minitest::Test
  # Dommy deviation: assign() and replace() both update the URL via
  # the same `internal_set_url` path and neither touches History.length.
  # The browser would push (assign) or overwrite (replace) the
  # current history entry; Dommy treats them identically as URL
  # updates. Relative updates preserve the current origin; an absolute
  # URL (with scheme + host) updates the origin too, matching the
  # browser's cross-origin navigation.

  include DommyTestHelper

  def setup
    @win = make_window
    @loc = @win.location
  end

  def test_assign_updates_pathname
    @loc.__js_call__("assign", ["/assigned"])
    assert_equal("/assigned", @loc.__js_get__("pathname"))
  end

  def test_replace_updates_pathname
    @loc.__js_call__("replace", ["/replaced"])
    assert_equal("/replaced", @loc.__js_get__("pathname"))
  end

  def test_assign_with_query_updates_search
    @loc.__js_call__("assign", ["/path?k=v"])
    assert_equal("/path", @loc.__js_get__("pathname"))
    assert_equal("?k=v", @loc.__js_get__("search"))
  end

  def test_assign_with_fragment_updates_hash
    @loc.__js_call__("assign", ["/path#frag"])
    assert_equal("#frag", @loc.__js_get__("hash"))
  end

  def test_reload_is_noop
    before = @loc.__js_get__("href")
    @loc.__js_call__("reload", [])
    assert_equal(before, @loc.__js_get__("href"))
  end
end
