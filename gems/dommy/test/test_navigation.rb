# frozen_string_literal: true

require_relative "test_helper"

# Navigation N0 + N1: the NavigationDelegate seam, hyperlink activation
# behavior, and same-document fragment navigation.
class TestNavigation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(
      "<a id='cross' href='/other'>go</a>" \
      "<a id='frag' href='#sec'>jump</a>" \
      "<section id='sec'>target</section>"
    )
    @doc = @win.document
    @delegate = @win.navigation_delegate # NullDelegate by default
  end

  # --- N0: the delegate seam ---

  def test_default_delegate_is_null_delegate_recording_attempts
    assert_instance_of(Dommy::Navigation::NullDelegate, @delegate)
    assert_empty(@delegate.attempts)
  end

  # --- N1: hyperlink activation behavior ---

  def test_cross_document_link_click_reaches_delegate
    @doc.get_element_by_id("cross").click

    assert_equal(1, @delegate.attempts.size)
    attempt = @delegate.attempts.first
    assert_equal(:link, attempt[:source])
    assert_equal("GET", attempt[:method])
    assert_match(%r{/other\z}, attempt[:url])
    # NullDelegate doesn't actually navigate, so the location is unchanged.
    assert_equal("/", @win.location.__js_get__("pathname"))
  end

  def test_click_on_descendant_activates_ancestor_anchor
    @doc.body.inner_html = "<a id='outer' href='/deep'><span id='inner'>z</span></a>"
    @doc.get_element_by_id("inner").click

    assert_equal(1, @delegate.attempts.size)
    assert_match(%r{/deep\z}, @delegate.attempts.first[:url])
  end

  def test_prevent_default_suppresses_link_navigation
    link = @doc.get_element_by_id("cross")
    link.add_event_listener("click", ->(e) { e.__js_call__("preventDefault", []) })
    link.click

    assert_empty(@delegate.attempts)
  end

  def test_anchor_without_href_does_not_navigate
    @doc.body.inner_html = "<a id='bare'>no href</a>"
    @doc.get_element_by_id("bare").click

    assert_empty(@delegate.attempts)
  end

  def test_download_anchor_does_not_navigate
    @doc.body.inner_html = "<a id='dl' href='/file.zip' download>save</a>"
    @doc.get_element_by_id("dl").click

    assert_empty(@delegate.attempts)
  end

  def test_synthetic_click_also_triggers_activation
    prevented = Dommy::Interaction::EventSynthesis.click(@doc.get_element_by_id("cross"))

    refute(prevented)
    assert_equal(1, @delegate.attempts.size)
    assert_match(%r{/other\z}, @delegate.attempts.first[:url])
  end

  # --- N1: same-document fragment navigation ---

  def test_fragment_link_click_is_same_document
    fired = []
    @win.add_event_listener("hashchange", ->(e) { fired << e.__js_get__("newURL") })

    @doc.get_element_by_id("frag").click

    # No cross-document navigation reaches the delegate.
    assert_empty(@delegate.attempts)
    assert_equal("#sec", @win.location.__js_get__("hash"))
    assert_equal(1, fired.size)
    assert_match(/#sec\z/, fired.first)
    # :target now selects the fragment's element.
    assert_equal(@doc.get_element_by_id("sec"), @doc.query_selector(":target"))
  end

  def test_hashchange_carries_full_urls
    seen = nil
    @win.add_event_listener("hashchange", ->(e) { seen = [e.__js_get__("oldURL"), e.__js_get__("newURL")] })
    @win.location.__js_set__("hash", "top")

    old_url, new_url = seen
    assert_match(%r{\Ahttp://localhost/}, new_url)
    assert_match(/#top\z/, new_url)
    refute_match(/#/, old_url) # started with no fragment
  end

  # --- N1: location methods route to the delegate for cross-document ---

  def test_location_assign_is_cross_document
    @win.location.__js_call__("assign", ["/next"])

    attempt = @delegate.attempts.first
    assert_equal(:location, attempt[:source])
    refute(attempt[:replace])
    assert_match(%r{/next\z}, attempt[:url])
  end

  def test_location_replace_sets_replace_flag
    @win.location.__js_call__("replace", ["/next"])
    assert(@delegate.attempts.first[:replace])
  end

  def test_location_reload_delegates_with_replace
    @win.location.__js_call__("reload", [])

    attempt = @delegate.attempts.first
    assert_equal(:reload, attempt[:source])
    assert(attempt[:replace])
  end

  def test_location_hash_setter_is_same_document
    @win.location.__js_set__("hash", "sec")
    assert_empty(@delegate.attempts)
    assert_equal("#sec", @win.location.__js_get__("hash"))
  end

  # --- N2: form submission (requestSubmit / submit) reaches the delegate ---

  def form_fixture(method: "get", action: "/search")
    @win = make_window(
      "<form id='f' action='#{action}' method='#{method}'>" \
      "<input name='q' value='hi'><input name='skip' disabled>" \
      "<button id='go' type='submit' name='btn' value='v'>go</button>" \
      "</form>"
    )
    @doc = @win.document
    @delegate = @win.navigation_delegate
    @doc.get_element_by_id("f")
  end

  def test_request_submit_fires_submit_event_and_navigates
    form = form_fixture(method: "get")
    events = []
    form.add_event_listener("submit", ->(e) { events << e.__js_get__("submitter") })

    form.__js_call__("requestSubmit", [@doc.get_element_by_id("go")])

    assert_equal(1, events.size)
    assert_equal(@doc.get_element_by_id("go"), events.first, "SubmitEvent exposes the submitter")

    attempt = @delegate.attempts.first
    assert_equal(:form, attempt[:source])
    assert_equal("GET", attempt[:method])
    assert_match(%r{/search\z}, attempt[:url])
    # ordered [name,value] pairs, disabled control excluded, submitter included
    assert_includes(attempt[:params], ["q", "hi"])
    assert_includes(attempt[:params], ["btn", "v"])
    refute(attempt[:params].any? { |name, _| name == "skip" })
  end

  def test_request_submit_prevent_default_suppresses_navigation
    form = form_fixture
    form.add_event_listener("submit", ->(e) { e.__js_call__("preventDefault", []) })
    form.__js_call__("requestSubmit", [])

    assert_empty(@delegate.attempts)
  end

  def test_submit_navigates_without_firing_event
    form = form_fixture(method: "post", action: "/create")
    events = []
    form.add_event_listener("submit", ->(_e) { events << 1 })

    form.__js_call__("submit", [])

    assert_empty(events, "submit() fires no submit event, per spec")
    attempt = @delegate.attempts.first
    assert_equal("POST", attempt[:method])
    assert_equal(:form, attempt[:source])
    assert_match(%r{/create\z}, attempt[:url])
  end

  def test_request_submit_rejects_non_submit_submitter
    form = form_fixture
    plain = @doc.query_selector("input[name=q]")
    assert_raises(TypeError) { form.request_submit(plain) }
  end

  # --- N1: pushState fragment change no longer double-signals hashchange ---

  def test_pushstate_fragment_does_not_fire_hashchange
    hashchanges = []
    @win.add_event_listener("hashchange", ->(_e) { hashchanges << 1 })
    @win.__js_get__("history").__js_call__("pushState", [{"n" => 1}, "", "#frag"])

    assert_empty(hashchanges)
    assert_equal("#frag", @win.location.__js_get__("hash"))
  end
end
