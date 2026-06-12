# frozen_string_literal: true

require_relative "test_helper"

# --- Element scroll / size --------------------------------------

class TestElementScrollAndSize < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='x'>hi</div>")
    @el = @win.document.query_selector("#x")
  end

  def test_scroll_into_view_records_call
    @el.__js_call__("scrollIntoView", [true])
    assert_equal([["scrollIntoView", [true]]], @el.__test_scroll_log__)
  end

  def test_scroll_to_records_call
    @el.__js_call__("scrollTo", [{"top" => 100, "behavior" => "smooth"}])
    assert_equal("scrollTo", @el.__test_scroll_log__.first.first)
  end

  def test_scroll_metrics_zero
    %w[scrollTop scrollLeft scrollWidth scrollHeight].each do |prop|
      assert_equal(0, @el.__js_get__(prop))
    end
  end

  def test_client_and_offset_metrics_zero
    %w[clientWidth clientHeight offsetWidth offsetHeight clientTop clientLeft offsetTop offsetLeft].each do |prop|
      assert_equal(0, @el.__js_get__(prop))
    end
  end

  def test_get_client_rects_empty
    assert_equal([], @el.__js_call__("getClientRects", []))
  end
end

# --- Popover API ------------------------------------------------

class TestPopoverAPI < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='p' popover='auto'>hi</div>")
    @el = @win.document.query_selector("#p")
  end

  def test_popover_attribute_exposed
    assert_equal("auto", @el.__js_get__("popover"))
  end

  def test_show_and_hide_fire_toggle_events
    events = []
    @el.add_event_listener("beforetoggle", proc { |e| events << "before:#{e.detail["newState"]}" })
    @el.add_event_listener("toggle", proc { |e| events << "toggle:#{e.detail["newState"]}" })
    @el.__js_call__("showPopover", [])
    @el.__js_call__("hidePopover", [])
    assert_equal(["before:open", "toggle:open", "before:closed", "toggle:closed"], events)
  end

  def test_toggle_popover_returns_new_state
    assert_equal(true, @el.__js_call__("togglePopover", []))
    assert_equal(false, @el.__js_call__("togglePopover", []))
  end
end

# --- Fullscreen API ---------------------------------------------

class TestFullscreenAPI < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='v'>video</div>")
    @el = @win.document.query_selector("#v")
  end

  def test_request_sets_fullscreen_element
    @el.__js_call__("requestFullscreen", [])
    assert_equal(@el, @win.document.__js_get__("fullscreenElement"))
  end

  def test_exit_clears_fullscreen_element
    @el.__js_call__("requestFullscreen", [])
    @win.document.exit_fullscreen
    assert_nil(@win.document.__js_get__("fullscreenElement"))
  end

  def test_request_fires_fullscreenchange
    fired = false
    @win.document.add_event_listener("fullscreenchange", proc { |_| fired = true })
    @el.__js_call__("requestFullscreen", [])
    assert(fired)
  end

  def test_fullscreen_enabled_true
    assert_equal(true, @win.document.__js_get__("fullscreenEnabled"))
  end
end

# --- getComputedStyle -------------------------------------------

class TestGetComputedStyle < Minitest::Test
  include DommyTestHelper

  def test_returns_computed_value_for_inline_style
    win = make_window("<div id='x' style='color: red'>hi</div>")
    el = win.document.query_selector("#x")
    cs = win.__js_call__("getComputedStyle", [el])
    # With the CSS cascade (makiri-backed) the value comes back in the
    # browser's computed serialization, not the author's spelling.
    assert_equal("rgb(255, 0, 0)", cs["color"])
  end
end

# --- View Transitions ------------------------------------------

class TestViewTransitions < Minitest::Test
  include DommyTestHelper

  def test_callback_invoked_synchronously
    win = make_window
    called = false
    win.document.__js_call__("startViewTransition", [proc { called = true }])
    assert(called)
  end

  def test_finished_ready_promises_resolved
    win = make_window
    tx = win.document.__js_call__("startViewTransition", [proc { }])
    assert_nil(tx.finished.await)
    assert_nil(tx.ready.await)
  end
end

# --- Navigator.locks / storage ---------------------------------

class TestNavigatorLocksStorage < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @nav = @win.navigator
  end

  def test_lock_request_invokes_callback_with_lock
    got = nil
    @nav.locks.request("res", proc { |lock| got = lock.name })
    assert_equal("res", got)
  end

  def test_storage_estimate
    e = @nav.storage.estimate.await
    assert_operator(e["quota"], :>, 0)
    assert_equal(0, e["usage"])
  end

  def test_storage_persist_round_trip
    assert_equal(true, @nav.storage.persist.await)
    assert_equal(true, @nav.storage.persisted.await)
  end
end

# --- URLPattern ------------------------------------------------

class TestURLPattern < Minitest::Test
  include DommyTestHelper

  def test_simple_path_match
    pat = Dommy::URLPattern.new({"pathname" => "/users/:id"})
    assert(pat.test("/users/42"))
    refute(pat.test("/posts/42"))
  end

  def test_exec_captures_named_groups
    pat = Dommy::URLPattern.new({"pathname" => "/users/:id"})
    r = pat.exec("/users/alice")
    assert_equal("alice", r["pathname"]["groups"]["id"])
  end

  def test_wildcard_captures_zero_based_name
    pat = Dommy::URLPattern.new({"pathname" => "/docs/*"})
    r = pat.exec("/docs/a/b/c")
    assert_equal("a/b/c", r["pathname"]["groups"]["0"])
  end

  def test_plus_modifier_matches_multiple_segments
    pat = Dommy::URLPattern.new({"pathname" => "/api/:version+"})
    assert(pat.test("/api/v1/sub"))
    assert(pat.test("/api/v1"))
  end

  def test_window_exposes_constructor
    win = make_window
    ctor = win.__js_get__("URLPattern")
    pat = ctor.__js_new__([{"pathname" => "/x"}])
    assert_kind_of(Dommy::URLPattern, pat)
  end
end

# --- SubtleCrypto AES-GCM --------------------------------------

class TestSubtleCryptoAESGCM < Minitest::Test
  include DommyTestHelper

  def setup
    @subtle = make_window.__js_get__("crypto").subtle
    @key = @subtle.import_key("raw", "a" * 16, {"name" => "AES-GCM"}).await
    @iv = "x" * 12
  end

  def test_encrypt_decrypt_roundtrip
    ct = @subtle.encrypt({"name" => "AES-GCM", "iv" => @iv}, @key, "secret").await
    pt = @subtle.decrypt({"name" => "AES-GCM", "iv" => @iv}, @key, ct.pack("C*")).await
    assert_equal("secret", pt.pack("C*"))
  end

  def test_decrypt_with_wrong_iv_raises
    ct = @subtle.encrypt({"name" => "AES-GCM", "iv" => @iv}, @key, "secret").await
    assert_raises(OpenSSL::Cipher::CipherError) do
      @subtle.decrypt({"name" => "AES-GCM", "iv" => "y" * 12}, @key, ct.pack("C*")).await
    end
  end

  def test_additional_data_authenticated
    ct = @subtle
      .encrypt(
        {"name" => "AES-GCM", "iv" => @iv, "additionalData" => "aad"},
        @key,
        "hi"
      )
      .await
    pt = @subtle
      .decrypt(
        {"name" => "AES-GCM", "iv" => @iv, "additionalData" => "aad"},
        @key,
        ct.pack("C*")
      )
      .await
    assert_equal("hi", pt.pack("C*"))
  end

  def test_aes_256
    key256 = @subtle.import_key("raw", "k" * 32, {"name" => "AES-GCM"}).await
    ct = @subtle.encrypt({"name" => "AES-GCM", "iv" => @iv}, key256, "longer data here").await
    pt = @subtle.decrypt({"name" => "AES-GCM", "iv" => @iv}, key256, ct.pack("C*")).await
    assert_equal("longer data here", pt.pack("C*"))
  end

  def test_custom_tag_length_round_trips
    # Default tagLength is 128 bits (16 bytes). With a custom value
    # the encrypt and decrypt sides must agree on the tag width —
    # dommy now sets `auth_tag_len` on encrypt to keep them symmetric.
    opts = {"name" => "AES-GCM", "iv" => @iv, "tagLength" => 96}
    ct = @subtle.encrypt(opts, @key, "tagged").await
    pt = @subtle.decrypt(opts, @key, ct.pack("C*")).await
    assert_equal("tagged", pt.pack("C*"))
  end

  def test_missing_iv_rejects
    assert_raises(ArgumentError) do
      @subtle.encrypt({"name" => "AES-GCM"}, @key, "x").await
    end
  end
end
