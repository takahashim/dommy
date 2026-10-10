# frozen_string_literal: true

require_relative "test_helper"

# Dommy::CookieJar: RFC 6265bis's storage model and cookie-string, shared by
# document.cookie, cookieStore and an embedder's requests.
class TestCookieJar < Minitest::Test
  URL = "http://example.test/dir/page"

  def setup
    @now = Time.utc(2026, 1, 1)
    @jar = Dommy::CookieJar.new(clock: -> { @now })
  end

  def store(string, url = URL, http: true) = @jar.store(string, url, http: http)
  def string(url = URL, http: true) = @jar.cookie_string(url, http: http)

  def test_stores_and_serializes_in_path_then_creation_order
    store("a=1; Path=/")
    store("b=2")
    store("c=3; Path=/")
    assert_equal "b=2; a=1; c=3", string
  end

  def test_name_value_parsing
    store("  spaced  =  value  ")
    store("flag")
    assert_equal "spaced=value; flag", string
  end

  def test_a_nameless_and_valueless_cookie_is_ignored
    assert_nil store("")
    assert_nil store("=")
    assert_equal "", string
  end

  def test_control_characters_reject_the_whole_string
    assert_nil store("b=A\0Z")
    assert_nil store("b=A\nZ")
    refute_nil store("b=A\tZ")
  end

  def test_size_limits
    assert_nil store("n=#{'x' * 4096}"), "name and value over 4096 octets"
    refute_nil store("n=#{'x' * 4095}")
    store("p=1; Path=/#{'x' * 1024}")
    assert_equal "/dir", @jar.all.find { |c| c.name == "p" }.path, "an oversized attribute value is ignored"
  end

  def test_expiry_in_the_past_deletes
    store("a=1")
    store("a=; expires=Thu, 01 Jan 1970 00:00:00 GMT")
    assert_equal "", string
    store("b=1")
    store("b=1; Max-Age=0")
    assert_equal "", string
  end

  def test_max_age_wins_over_expires_and_both_are_capped
    cookie = store("a=1; Expires=Wed, 01 Jan 2025 00:00:00 GMT; Max-Age=60")
    assert_equal @now + 60, cookie.expires
    far = store("b=1; Max-Age=999999999")
    assert_equal @now + (400 * 86_400), far.expires
  end

  def test_expired_cookies_disappear_as_time_passes
    store("a=1; Max-Age=10")
    @now += 11
    assert_equal "", string
  end

  def test_cookie_date_parsing
    assert_equal Time.utc(2026, 6, 9, 10, 18, 14), store("a=1; Expires=Tue, 09 Jun 2026 10:18:14 GMT").expires
    assert_equal Time.utc(2026, 6, 9, 10, 18, 14), store("a=1; expires=09-Jun-26 10:18:14").expires
    assert_nil store("a=1; Expires=Wed").expires, "an unparsable date is ignored"
  end

  def test_default_path_and_path_matching
    store("d=1")
    assert_equal "/dir", @jar.all.first.path
    assert_equal "d=1", string("http://example.test/dir/other")
    assert_equal "", string("http://example.test/directory")
    assert_equal "", string("http://example.test/")
  end

  def test_host_only_and_domain_cookies
    store("h=1")
    store("d=1; Domain=.Example.test")
    assert_equal "h=1; d=1", string("http://example.test/dir/")
    assert_equal "d=1", string("http://www.example.test/dir/")
    assert_nil store("x=1; Domain=other.test"), "a Domain the host does not domain-match"
    assert_nil store("x=1; Domain=test"), "a single label stands in for a public suffix"
  end

  def test_secure_cookies
    assert_nil store("s=1; Secure"), "Secure from an insecure URL"
    refute_nil store("s=1; Secure", "https://example.test/")
    assert_equal "", string("http://example.test/")
    assert_equal "s=1", string("https://example.test/")
    assert_nil store("s=2", "http://example.test/"), "an insecure cookie cannot shadow a secure one"
  end

  # The path the insecure cookie is refused under is the secure one's and
  # below it, not above.
  def test_an_insecure_cookie_cannot_shadow_a_secure_one_below_its_path
    refute_nil store("sid=good; Secure; Path=/app", "https://example.test/app/")
    assert_nil store("sid=evil; Path=/app/x", "http://example.test/app/x/")
    refute_nil store("sid=other; Path=/", "http://example.test/")
    assert_equal "sid=good; sid=other", string("https://example.test/app/")
  end

  def test_httponly_is_hidden_from_and_protected_against_non_http_apis
    store("h=1; HttpOnly; Path=/")
    assert_equal "h=1", string("http://example.test/")
    assert_equal "", string("http://example.test/", http: false)
    assert_nil store("h=2; Path=/", "http://example.test/", http: false)
    assert_nil store("j=1; HttpOnly", http: false)
    assert_equal "h=1", string("http://example.test/")
  end

  def test_same_site_none_requires_secure
    assert_nil store("n=1; SameSite=None", "https://example.test/")
    assert_equal "None", store("n=1; SameSite=None; Secure", "https://example.test/").same_site
    assert_equal "Lax", store("l=1; samesite=lax").same_site
  end

  def test_prefixes
    assert_nil store("__Secure-a=1", "https://example.test/")
    refute_nil store("__Secure-a=1; Secure", "https://example.test/")
    assert_nil store("__Host-a=1; Secure; Domain=example.test; Path=/", "https://example.test/")
    refute_nil store("__Host-a=1; Secure; Path=/", "https://example.test/")
    assert_nil store("=__Host-x", "https://example.test/")
  end

  def test_overwriting_keeps_creation_order
    store("a=1; Path=/")
    store("b=1; Path=/")
    store("a=2; Path=/")
    assert_equal "a=2; b=1", string
  end

  def test_a_loopback_host_counts_as_secure
    refute_nil store("s=1; Secure", "http://localhost/")
    assert_equal "s=1", string("http://localhost/")
  end

  def test_only_http_and_ws_urls_have_cookies
    assert_nil store("a=1", "about:blank")
    assert_equal "", string("data:text/html,x")
  end

  def test_export_and_import_round_trip
    store("a=1; Domain=example.test; Path=/; Max-Age=60")
    fresh = Dommy::CookieJar.new(clock: -> { @now })
    @jar.export.each { |h| fresh.import!(h) }
    assert_equal "a=1", fresh.cookie_string("http://www.example.test/")
  end
end

# A Dommy::Browser keeps one jar: its pages' document.cookie, its
# navigations' and its fetches' Cookie / Set-Cookie.
class TestBrowserCookies < Minitest::Test
  require_relative "support/null_runtime"

  def teardown
    @browser&.dispose
  end

  # A resources adapter that records each request's Cookie header and answers
  # with the Set-Cookie it was given for that path.
  class Recorder
    attr_reader :cookies_sent

    def initialize(set_cookies)
      @set_cookies = set_cookies
      @cookies_sent = []
    end

    def request(method:, url:, headers: {}, body: nil)
      path = URI.parse(url).path
      @cookies_sent << [path, headers["Cookie"]]
      hdrs = {"Content-Type" => "text/html"}
      hdrs["Set-Cookie"] = @set_cookies[path] if @set_cookies[path]
      Dommy::Resources::Response.new(status: 200, status_text: "OK", headers: hdrs,
                                     body: "<!doctype html><p>#{path}</p>", url: url, redirected: false)
    end
  end

  def test_navigations_fetches_and_document_cookie_share_the_jar
    res = Recorder.new("/" => "sid=1; Path=/", "/api" => "api=2; Path=/\nh=3; Path=/; HttpOnly")
    @browser = Dommy::Browser.visit("http://localhost/", resources: res, backend: :null)
    assert_equal "sid=1", @browser.document.cookie

    handler = @browser.window.globals["__fetch_handler__"]
    handler.call("http://localhost/api", {})
    assert_equal "sid=1; api=2", @browser.document.cookie, "an HttpOnly cookie stays hidden"
    assert_equal ["/api", "sid=1"], res.cookies_sent.last

    @browser.document.cookie = "js=4; Path=/"
    handler.call("http://other.test/x", {})
    assert_equal ["/x", nil], res.cookies_sent.last, "a cross-origin same-origin-mode request is uncredentialed"
    handler.call("http://localhost/y", {"credentials" => "omit"})
    assert_nil res.cookies_sent.last[1]

    @browser.visit("http://localhost/next")
    assert_equal ["/next", "sid=1; api=2; h=3; js=4"], res.cookies_sent.last
  end
end

# HTML's document.cookie over the window's jar.
class TestDocumentCookie < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @win.location.__internal_set_url__("http://example.test/a/b")
    @doc = @win.document
  end

  def test_reads_and_writes_the_windows_jar_as_a_non_http_api
    @win.cookie_jar.store("h=1; HttpOnly; Path=/", "http://example.test/")
    @doc.cookie = "a=1"
    @doc.cookie = "b=A\0Z"
    assert_equal "a=1", @doc.cookie
    @doc.cookie = "a=; expires=Thu, 01 Jan 1970 00:00:00 GMT"
    assert_equal "", @doc.cookie
  end

  def test_a_document_without_a_browsing_context_is_cookie_averse
    doc = @doc.implementation.create_html_document("x")
    doc.cookie = "a=1"
    assert_equal "", doc.cookie
  end

  def test_a_non_http_url_is_cookie_averse
    frame = @doc.create_element("iframe")
    @doc.body.append_child(frame)
    inner = frame.content_document
    inner.cookie = "a=1"
    assert_equal "", inner.cookie
    assert_equal "", @doc.cookie
  end

  def test_frames_share_their_containers_jar
    frame = @doc.create_element("iframe")
    @doc.body.append_child(frame)
    assert_same @win.cookie_jar, frame.content_window.cookie_jar
  end

  def test_an_opaque_origin_throws
    @win.__internal_opaque_origin__ = true
    assert_raises(Dommy::DOMException::SecurityError) { @doc.cookie }
    assert_raises(Dommy::DOMException::SecurityError) { @doc.cookie = "a=1" }
  end
end
