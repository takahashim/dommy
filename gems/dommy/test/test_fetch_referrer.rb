# frozen_string_literal: true

require_relative "test_helper"

# The Referer a page's fetch() and XMLHttpRequest carry: the document's URL
# under the request's referrer policy (else the document's `<meta
# name="referrer">`, else strict-origin-when-cross-origin), and a RequestInit's
# `referrer` / `referrerPolicy`.
class TestFetchReferrer < Minitest::Test
  include DommyTestHelper

  class RecordingHandler
    attr_reader :headers

    def call(_url, init)
      @headers = init["headers"]
      {"status" => 200, "body" => ""}
    end
  end

  def setup
    @win = make_window
    @win.location.__internal_set_url__("https://user:pw@a.test/dir/page?q=1#frag")
    @handler = RecordingHandler.new
    @win.globals["__fetch_handler__"] = @handler
  end

  def fetch(*args) = Dommy::FetchFn.new(@win).__js_call__("fetch", args)

  # The Referer the fetch sent, or nil.
  def referer(url, init = nil)
    fetch(url, init)
    @handler.headers&.find { |name, _| name.casecmp?("referer") }&.last
  end

  def test_a_same_origin_request_sends_the_url_without_credentials_or_fragment
    assert_equal("https://a.test/dir/page?q=1", referer("/api"))
  end

  def test_a_cross_origin_request_sends_the_origin_and_a_downgrade_none
    assert_equal("https://a.test/", referer("https://b.test/api"))
    assert_nil(referer("http://b.test/api"))
  end

  def test_the_request_policy_decides
    assert_nil(referer("/api", {"referrerPolicy" => "no-referrer"}))
    assert_equal("https://a.test/", referer("/api", {"referrerPolicy" => "origin"}))
    assert_equal("https://a.test/dir/page?q=1", referer("http://b.test/api", {"referrerPolicy" => "unsafe-url"}))
    assert_nil(referer("https://b.test/api", {"referrerPolicy" => "same-origin"}))
  end

  def test_the_documents_meta_referrer_is_the_default_policy
    meta = @win.document.create_element("meta")
    meta.set_attribute("name", "Referrer")
    meta.set_attribute("content", "origin")
    @win.document.head.append_child(meta)

    assert_equal("https://a.test/", referer("/api"))
    assert_equal("https://a.test/dir/page?q=1", referer("/api", {"referrerPolicy" => "unsafe-url"}))
  end

  def test_the_request_referrer_is_none_a_same_origin_url_or_the_page
    assert_nil(referer("/api", {"referrer" => ""}))
    assert_equal("https://a.test/other", referer("/api", {"referrer" => "/other#x"}))
    assert_equal("https://a.test/dir/page?q=1", referer("/api", {"referrer" => "https://b.test/elsewhere"}))
  end

  def test_a_referer_the_caller_set_is_replaced
    assert_equal("https://a.test/dir/page?q=1", referer("/api", {"headers" => {"Referer" => "https://evil.test/"}}))
    assert_nil(referer("/api", {"headers" => {"referer" => "https://evil.test/"}, "referrer" => ""}))
  end

  def test_a_requests_referrer_and_policy_are_sent_and_read_back
    # The referrer is the URL as parsed (credentials too); the header strips it.
    request = Dommy::Request.new("/api", {"referrer" => "/other", "referrerPolicy" => "origin"}, @win)
    assert_equal(["https://user:pw@a.test/other", "origin"], [request.__js_get__("referrer"), request.__js_get__("referrerPolicy")])
    assert_equal("https://a.test/", referer(request))

    assert_equal(["about:client", ""], %w[referrer referrerPolicy].map { |key| Dommy::Request.new("/api", nil, @win).__js_get__(key) })
    assert_equal("", Dommy::Request.new("/api", {"referrer" => ""}, @win).__js_get__("referrer"))
  end

  def test_an_invalid_referrer_or_policy_rejects
    [{"referrer" => "http://["}, {"referrerPolicy" => "sometimes"}].each do |init|
      assert_raises(Dommy::Bridge::TypeError, init.inspect) { fetch("/api", init).await }
    end
    assert_raises(Dommy::Bridge::TypeError) { Dommy::Request.new("/api", {"referrerPolicy" => "sometimes"}, @win) }
  end

  def test_a_document_without_a_url_of_its_own_sends_none
    @win.location.__internal_set_url__("about:blank")
    assert_nil(referer("http://localhost/api"))
  end

  def test_xhr_sends_the_referer
    xhr = Dommy::XMLHttpRequest.new(@win)
    xhr.open("GET", "https://b.test/api", false)
    xhr.set_request_header("Referer", "https://evil.test/")
    xhr.send

    assert_equal(["https://a.test/"], @handler.headers.select { |name, _| name.casecmp?("referer") }.values)
  end
end
