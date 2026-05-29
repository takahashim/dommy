# frozen_string_literal: true

require_relative "test_helper"

class TestNavigatorBasics < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @nav = @win.navigator
  end

  def test_window_has_navigator
    assert_kind_of(Dommy::Navigator, @nav)
  end

  def test_default_user_agent
    assert_match(/Dommy/, @nav.user_agent)
  end

  def test_default_language
    assert_equal("en", @nav.language)
    assert_equal(["en"], @nav.languages.to_a)
  end

  def test_default_platform_vendor
    assert_equal("Dommy", @nav.platform)
    assert_equal("Dommy", @nav.vendor)
  end

  def test_default_on_line
    assert_equal(true, @nav.on_line)
  end

  def test_default_cookie_enabled
    assert_equal(true, @nav.cookie_enabled)
  end

  def test_user_agent_setter
    @nav.user_agent = "test-agent/1.0"
    assert_equal("test-agent/1.0", @nav.user_agent)
    assert_equal("test-agent/1.0", @nav.__js_get__("userAgent"))
  end

  def test_js_get_routes
    assert_equal(@nav.platform, @nav.__js_get__("platform"))
    assert_equal(@nav.language, @nav.__js_get__("language"))
    assert_equal(@nav.cookie_enabled, @nav.__js_get__("cookieEnabled"))
  end

  def test_navigator_via_window_js_get
    via_js = @win.__js_get__("navigator")
    assert_same(@nav, via_js)
  end
end

class TestClipboard < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @clipboard = @win.navigator.clipboard
  end

  def test_clipboard_initial_empty
    assert_equal("", @clipboard.text)
  end

  def test_write_text_round_trip
    promise = @clipboard.write_text("hello")
    received = nil
    promise.__js_call__("then", [proc { |v| received = v }])
    @win.scheduler.drain_microtasks
    assert_nil(received)

    rt = @clipboard.read_text
    got = nil
    rt.__js_call__("then", [proc { |v| got = v }])
    @win.scheduler.drain_microtasks
    assert_equal("hello", got)
  end

  def test_write_text_overrides_previous
    @clipboard.write_text("first")
    @clipboard.write_text("second")
    @win.scheduler.drain_microtasks
    assert_equal("second", @clipboard.text)
  end

  def test_text_accessor_synchronous_for_tests
    @clipboard.text = "direct set"
    assert_equal("direct set", @clipboard.text)
  end

  def test_js_call_routes
    @clipboard.__js_call__("writeText", ["via js_call"])
    @win.scheduler.drain_microtasks
    assert_equal("via js_call", @clipboard.text)
  end

  def test_clipboard_is_event_target
    fired = false
    @clipboard.add_event_listener("copy", proc { fired = true })
    @clipboard.dispatch_event(Dommy::Event.new("copy"))
    assert(fired)
  end
end

class TestPermissions < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @perms = @win.navigator.permissions
  end

  def test_query_default_granted
    promise = @perms.query({"name" => "clipboard-write"})
    status = nil
    promise.__js_call__("then", [proc { |v| status = v }])
    @win.scheduler.drain_microtasks
    refute_nil(status)
    assert_equal("granted", status.state)
    assert_equal("clipboard-write", status.name)
  end

  def test_query_accepts_string_name
    promise = @perms.query("notifications")
    status = nil
    promise.__js_call__("then", [proc { |v| status = v }])
    @win.scheduler.drain_microtasks
    assert_equal("granted", status.state)
  end

  def test_set_overrides_subsequent_query
    @perms.set("notifications", "denied")
    promise = @perms.query({"name" => "notifications"})
    status = nil
    promise.__js_call__("then", [proc { |v| status = v }])
    @win.scheduler.drain_microtasks
    assert_equal("denied", status.state)
  end

  def test_set_fires_change_on_existing_status
    # Acquire status first (default granted), then flip via set().
    promise = @perms.query("camera")
    status = nil
    promise.__js_call__("then", [proc { |v| status = v }])
    @win.scheduler.drain_microtasks
    assert_equal("granted", status.state)

    fired = false
    status.add_event_listener("change", proc { fired = true })

    @perms.set("camera", "denied")
    assert(fired)
    assert_equal("denied", status.state)
  end

  def test_onchange_property_setter
    promise = @perms.query("microphone")
    status = nil
    promise.__js_call__("then", [proc { |v| status = v }])
    @win.scheduler.drain_microtasks

    received_event = nil
    status.__js_set__("onchange", proc { |e| received_event = e })

    @perms.set("microphone", "denied")
    refute_nil(received_event)
    assert_equal("change", received_event.__js_get__("type"))
  end

  def test_status_state_idempotent_no_event
    promise = @perms.query("camera")
    status = nil
    promise.__js_call__("then", [proc { |v| status = v }])
    @win.scheduler.drain_microtasks

    fired = false
    status.add_event_listener("change", proc { fired = true })
    # same as current
    @perms.set("camera", "granted")
    refute(fired)
  end
end
