# frozen_string_literal: true

require "test_helper"
require_relative "support/null_runtime"

# HTML "Browsing the web" and "The Window object" behaviour reachable from Ruby:
# session history entries, Location-object navigation, fragment navigation,
# pushState / replaceState, delegate seams for the joint session history,
# nested browsing contexts, window.open targets, page lifecycle events,
# origins and Web Storage shared across a browsing session.
class TestBrowsingContext < Minitest::Test
  include DommyTestHelper

  def window_at(url, body = "")
    win = make_window(body)
    win.location.__internal_set_url__(url)
    win
  end

  def run_tasks(win) = win.scheduler.advance_time(0)

  def history(win) = win.__js_get__("history")

  # --- session history entry 0 ---

  def test_first_entry_is_the_document_url_set_after_construction
    win = window_at("https://a.test/start?q=1")
    history(win).__js_call__("pushState", [nil, "", "/next"])
    history(win).__js_call__("back", [])
    run_tasks(win)

    assert_equal "https://a.test/start?q=1", win.location.href
  end

  # --- traversal is asynchronous; go(0) reloads ---

  def test_back_runs_from_a_task_and_fires_trusted_popstate
    win = window_at("https://a.test/")
    events = []
    win.add_event_listener("popstate", ->(e) { events << [e.__js_get__("state"), e.__js_get__("isTrusted"), e.__js_get__("hasUAVisualTransition")] })
    history(win).__js_call__("pushState", [{"n" => 1}, "", "/a"])
    history(win).__js_call__("pushState", [{"n" => 2}, "", "/b"])
    history(win).__js_call__("back", [])

    assert_empty events
    assert_equal "https://a.test/b", win.location.href
    run_tasks(win)
    assert_equal [[{"n" => 1}, true, false]], events
    assert_equal "https://a.test/a", win.location.href
  end

  def test_go_zero_reloads_through_the_delegate
    win = window_at("https://a.test/x")
    history(win).__js_call__("go", [0])

    attempt = win.navigation_delegate.attempts.last
    assert_equal "https://a.test/x", attempt[:url]
    assert_equal :reload, attempt[:source]
  end

  def test_traversal_past_the_documents_entries_goes_to_the_delegate
    win = window_at("https://a.test/")
    history(win).__js_call__("go", [-2])
    run_tasks(win)

    assert_equal({traverse: -2, source: :traverse}, win.navigation_delegate.attempts.last)
  end

  def test_length_comes_from_the_joint_history_when_the_delegate_keeps_one
    win = window_at("https://a.test/")
    delegate = Dommy::Navigation::NullDelegate.new
    delegate.define_singleton_method(:history_length) { 7 }
    win.navigation_delegate = delegate

    assert_equal 7, history(win).__js_get__("length")
  end

  # --- fragment navigation ---

  def test_hash_setter_pushes_an_entry_fires_popstate_now_and_hashchange_later
    win = window_at("https://a.test/p")
    log = []
    win.add_event_listener("popstate", ->(e) { log << [:popstate, e.__js_get__("state")] })
    win.add_event_listener("hashchange", ->(e) { log << [:hashchange, e.__js_get__("newURL"), e.__js_get__("isTrusted")] })
    win.location.__js_set__("hash", "x")

    assert_equal 2, history(win).__js_get__("length")
    assert_equal [[:popstate, nil]], log
    run_tasks(win)
    assert_equal [:hashchange, "https://a.test/p#x", true], log.last
    assert_empty win.navigation_delegate.attempts
  end

  def test_location_replace_with_a_fragment_replaces_the_entry
    win = window_at("https://a.test/p")
    win.location.__js_call__("replace", ["#y"])

    assert_equal 1, history(win).__js_get__("length")
    assert_equal "#y", win.location.__js_get__("hash")
  end

  def test_fragment_link_click_pushes_an_entry
    win = window_at("https://a.test/p", "<a id='go' href='#sec'>go</a><p id='sec'></p>")
    win.document.get_element_by_id("go").click

    assert_equal 2, history(win).__js_get__("length")
    assert_equal "https://a.test/p#sec", win.location.href
  end

  # Dropping the fragment is not a fragment navigation: it goes to the network.
  def test_same_url_without_a_fragment_is_cross_document
    win = window_at("https://a.test/p#x")
    win.location.__js_set__("href", "https://a.test/p")

    assert_equal "https://a.test/p", win.navigation_delegate.attempts.last[:url]
  end

  def test_navigating_to_the_document_url_itself_replaces
    win = window_at("https://a.test/p")
    win.location.__js_set__("href", "https://a.test/p")

    assert win.navigation_delegate.attempts.last[:replace]
  end

  def test_navigation_while_loading_replaces
    win = window_at("https://a.test/p")
    win.document.__internal_set_ready_state__("loading")
    win.location.__js_set__("hash", "early")

    assert_equal 1, history(win).__js_get__("length")
  end

  # Only without transient user activation: a click during the load adds an
  # entry.
  def test_navigation_while_loading_with_user_activation_adds_an_entry
    win = window_at("https://a.test/p")
    win.document.__internal_set_ready_state__("loading")
    win.__internal_notify_activation__
    win.location.__js_set__("href", "https://a.test/next")

    refute win.navigation_delegate.attempts.last[:replace]
  end

  # --- Location setters navigate ---

  def test_pathname_search_host_and_port_setters_navigate
    {
      "pathname" => ["/other", "https://a.test/other"],
      "search" => ["q=1", "https://a.test/p?q=1"],
      "host" => ["b.test:8443", "https://b.test:8443/p"],
      "hostname" => ["c.test", "https://c.test/p"],
      "port" => ["444", "https://a.test:444/p"]
    }.each do |key, (value, expected)|
      win = window_at("https://a.test/p")
      win.location.__js_set__(key, value)
      assert_equal expected, win.navigation_delegate.attempts.last&.fetch(:url), key
    end
  end

  def test_protocol_setter_navigates_only_to_http_schemes
    win = window_at("https://a.test/p")
    win.location.__js_set__("protocol", "http")
    assert_equal "http://a.test/p", win.navigation_delegate.attempts.last[:url]

    win2 = window_at("https://a.test/p")
    win2.location.__js_set__("protocol", "ftp")
    assert_empty win2.navigation_delegate.attempts
    assert_raises(Dommy::DOMException::SyntaxError) { win2.location.__js_set__("protocol", "1x") }
  end

  def test_search_setter_with_the_same_query_still_navigates
    win = window_at("https://a.test/p?a")
    win.location.__js_set__("search", "a")

    assert_equal "https://a.test/p?a", win.navigation_delegate.attempts.last[:url]
  end

  # --- pushState / replaceState ---

  def test_push_state_serializes_before_checking_the_url
    win = window_at("https://a.test/p")
    assert_raises(Dommy::DOMException::DataCloneError) do
      history(win).__js_call__("pushState", [proc {}, "", "https://other.test/"])
    end
  end

  def test_empty_url_keeps_the_document_url_with_its_fragment
    win = window_at("https://a.test/p#frag")
    history(win).__js_call__("pushState", [1, "", ""])

    assert_equal "https://a.test/p#frag", win.location.href
    assert_equal 2, history(win).__js_get__("length")
  end

  def test_url_rewrite_rules
    win = window_at("https://a.test/p")
    assert_raises(Dommy::DOMException::SecurityError) { history(win).__js_call__("pushState", [nil, "", "https://a.test:444/p"]) }
    assert_raises(Dommy::DOMException::SecurityError) { history(win).__js_call__("pushState", [nil, "", "https://u@a.test/p"]) }

    file = window_at("file:///dir/a.html")
    history(file).__js_call__("pushState", [nil, "", "?q#f"])
    assert_equal "file:///dir/a.html?q#f", file.location.href
    assert_raises(Dommy::DOMException::SecurityError) { history(file).__js_call__("pushState", [nil, "", "b.html"]) }

    data = window_at("data:text/html,hi")
    assert_raises(Dommy::DOMException::SecurityError) { history(data).__js_call__("pushState", [nil, "", "data:text/html,ho"]) }
  end

  def test_state_is_the_same_object_until_the_entry_changes
    win = window_at("https://a.test/p")
    history(win).__js_call__("pushState", [{"a" => 1}, ""])
    state = history(win).__js_get__("state")

    assert_same state, history(win).__js_get__("state")
  end

  def test_history_of_a_removed_frame_throws
    win = make_window("<iframe></iframe>")
    frame = win.document.query_selector("iframe")
    inner = frame.content_window
    frame.remove

    assert_raises(Dommy::DOMException::SecurityError) { history(inner).__js_get__("length") }
  end

  # --- nested browsing contexts ---

  def test_parent_top_frame_element_and_name_of_a_frame
    win = make_window("<iframe name='kid'></iframe>")
    frame = win.document.query_selector("iframe")
    inner = frame.content_window

    assert_same win, inner.__js_get__("parent")
    assert_same win, inner.__js_get__("top")
    assert_same frame, inner.__js_get__("frameElement")
    assert_equal "kid", inner.__js_get__("name")
    assert_nil inner.__js_get__("opener")
    refute inner.__js_get__("closed")
    inner.__js_set__("name", "renamed")
    assert_equal "renamed", inner.__js_get__("name")

    frame.remove
    assert_nil inner.__js_get__("parent")
    assert_nil inner.__js_get__("top")
    assert_nil inner.__js_get__("frameElement")
    assert_equal "", inner.__js_get__("name")
    assert inner.__js_get__("closed")
  end

  def test_top_level_window_refers_to_itself
    win = make_window
    assert_same win, win.__js_get__("parent")
    assert_same win, win.__js_get__("top")
    assert_nil win.__js_get__("frameElement")
  end

  # --- window.open ---

  def test_open_targets_existing_navigables
    win = window_at("https://a.test/p", "<iframe name='kid'></iframe>")
    inner = win.document.query_selector("iframe").content_window

    assert_same win, win.__js_call__("open", ["#x", "_self"])
    assert_equal "#x", win.location.__js_get__("hash")
    assert_same inner, win.__js_call__("open", ["", "kid"])
    assert_same win, inner.__js_call__("open", ["", "_parent"])
    assert_same win, inner.__js_call__("open", ["", "_top"])
  end

  def test_open_of_a_new_browsing_context_is_recorded_and_blocked
    win = window_at("https://a.test/p")

    assert_nil win.__js_call__("open", ["/popup", "_blank", "width=100"])
    assert_equal [{url: "https://a.test/popup", target: "_blank", features: "width=100"}], win.__test_open_calls__
    assert_raises(Dommy::DOMException::SyntaxError) { win.__js_call__("open", ["https://[bad", ""]) }
  end

  # --- print / close / stop / misc ---

  def test_print_fires_trusted_beforeprint_and_afterprint
    win = make_window
    events = []
    %w[beforeprint afterprint].each { |t| win.add_event_listener(t, ->(e) { events << [t, e.__js_get__("isTrusted")] }) }
    win.__js_call__("print", [])

    assert_equal [["beforeprint", true], ["afterprint", true]], events
    assert_equal 1, win.__test_print_calls__
  end

  def test_print_while_loading_waits_for_the_load
    win = make_window
    win.document.__internal_set_ready_state__("loading")
    win.__js_call__("print", [])
    assert_equal 0, win.__test_print_calls__

    win.document.__internal_set_ready_state__("complete")
    assert_equal 1, win.__test_print_calls__
  end

  def test_close_of_a_single_entry_top_level_window
    win = make_window
    refute win.__js_get__("closed")
    win.__js_call__("close", [])

    assert win.__js_get__("closed")
    assert_equal [{closable: true}], win.__test_close_calls__
  end

  def test_close_is_refused_once_the_session_has_more_entries
    win = window_at("https://a.test/")
    history(win).__js_call__("pushState", [nil, "", "/b"])
    win.__js_call__("close", [])

    refute win.__js_get__("closed")
  end

  def test_window_bar_props_status_and_secure_context
    win = window_at("https://a.test/")
    bar = win.__js_get__("toolbar")

    assert_same bar, win.__js_get__("toolbar")
    assert_equal true, bar.__js_get__("visible")
    assert_equal "", win.__js_get__("status")
    win.__js_set__("status", "busy")
    assert_equal "busy", win.__js_get__("status")
    assert_equal true, win.__js_get__("isSecureContext")
    assert_equal false, window_at("http://a.test/").__js_get__("isSecureContext")
    assert_equal true, window_at("http://localhost:3000/").__js_get__("isSecureContext")
    assert_equal false, win.__js_get__("crossOriginIsolated")
    %w[stop focus blur moveTo moveBy resizeBy captureEvents releaseEvents].each do |m|
      assert_nil win.__js_call__(m, [])
    end
  end

  def test_replaceable_attribute_assignment_shadows_the_getter
    win = make_window
    win.__js_set__("parent", 5)
    assert_equal 5, win.__js_get__("parent")
  end

  # --- page lifecycle ---

  def test_load_is_trusted_targets_the_document_and_is_followed_by_pageshow
    win = make_window
    seen = []
    win.add_event_listener("load", ->(e) { seen << ["load", e.__js_get__("isTrusted"), e.__js_get__("target").equal?(win.document)] })
    win.add_event_listener("pageshow", ->(e) { seen << [e.class.name, e.__js_get__("persisted"), e.__js_get__("target").equal?(win.document)] })
    win.document.__internal_set_ready_state__("loading")
    win.document.__internal_set_ready_state__("complete")

    assert_equal [["load", true, true], ["Dommy::PageTransitionEvent", false, true]], seen
  end

  # --- origins ---

  def test_about_blank_location_origin_is_opaque_but_the_frame_inherits_its_creators
    win = window_at("https://a.test/p", "<iframe></iframe>")
    inner = win.document.query_selector("iframe").content_window

    assert_equal "null", inner.location.__js_get__("origin")
    assert_equal "https://a.test", inner.origin
    assert_equal "a.test", inner.document.__js_get__("domain")
  end

  def test_document_domain_setter
    win = window_at("https://sub.example.test/")
    doc = win.document

    assert_raises(Dommy::DOMException::SecurityError) { doc.__js_set__("domain", "other.test") }
    assert_raises(Dommy::DOMException::SecurityError) { doc.__js_set__("domain", "test") }
    doc.__js_set__("domain", "example.test")
    assert_equal "example.test", doc.__js_get__("domain")
    assert_raises(Dommy::DOMException::SecurityError) { window_at("data:text/html,x").document.__js_set__("domain", "x") }
  end

  # --- Web Storage across windows ---

  def test_windows_sharing_a_provider_share_storage_and_hear_each_others_changes
    provider = Dommy::StorageProvider.new
    a = window_at("https://a.test/1")
    b = window_at("https://a.test/2")
    other = window_at("https://b.test/")
    [a, b, other].each { |w| w.storage_provider = provider }
    heard = []
    b.add_event_listener("storage", ->(e) { heard << [e.key, e.old_value, e.new_value, e.url, e.storage_area.equal?(b.local_storage), e.__js_get__("isTrusted")] })
    a.add_event_listener("storage", ->(_e) { heard << :self })

    a.local_storage.set_item("k", "v")
    assert_equal "v", b.local_storage.get_item("k")
    assert_nil other.local_storage.get_item("k")
    assert_empty heard # queued as a task
    run_tasks(b)
    run_tasks(a)
    assert_equal [["k", nil, "v", "https://a.test/1", true, true]], heard
  end

  def test_storage_of_an_opaque_origin_throws
    win = window_at("data:text/html,x")
    assert_raises(Dommy::DOMException::SecurityError) { win.__js_get__("localStorage") }
  end

  # --- Browser: joint history, beforeunload, referrer, shared storage ---

  def html(body) = "<!doctype html><html><head></head><body>#{body}</body></html>"

  def browser(pages)
    resources = Dommy::Resources.static(pages.transform_values { |v| {"body" => v, "content_type" => "text/html"} })
    @browser = Dommy::Browser.visit("http://localhost/", resources: resources, backend: :null)
  end

  def teardown
    @browser&.dispose
  end

  def test_browser_mirrors_push_state_into_its_joint_history
    b = browser("/" => html("home"))
    b.window.history.__js_call__("pushState", [nil, "", "/pushed"])

    assert_equal %w[http://localhost/ http://localhost/pushed], b.history.entries
    assert_equal 2, b.window.history.__js_get__("length")
    b.back
    assert_equal "http://localhost/", b.current_url
  end

  def test_browser_beforeunload_hook_can_keep_the_page
    b = browser("/" => html("<a href='/next'>next</a>"), "/next" => html("next"))
    b.window.add_event_listener("beforeunload", ->(e) { e.__js_call__("preventDefault", []) })
    b.on_before_unload { |_window, _event| false }
    b.click_link("next")

    assert_equal "http://localhost/", b.current_url
  end

  def test_browser_passes_the_referrer_and_shares_local_storage_across_pages
    b = browser("/" => html("<a href='/next'>next</a>"), "/next" => html("next"))
    b.window.local_storage.set_item("k", "kept")
    first = b.window
    b.click_link("next")

    assert_equal "http://localhost/", b.document.__js_get__("referrer")
    assert_equal "kept", b.window.local_storage.get_item("k")
    refute first.__internal_fully_active__?
  end
end
