# frozen_string_literal: true

require_relative "test_helper"

# fetch() follows a redirect to the Location the URL parser makes of it, and
# a response's URL is exposed without its fragment.
class TestFetchRedirect < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @win.globals["__fetchy_stub__"] = {
      "/r-utf8" => {"status" => 302, "headers" => {"Location" => "/\u65E5 x"}},
      "/%E6%97%A5%20x" => {"status" => 200, "body" => "utf8"},
      "/r-scheme" => {"status" => 302, "headers" => {"Location" => "http:done"}},
      "/done" => {"status" => 200, "body" => "done"}
    }
  end

  def fetch(url) = Dommy::FetchFn.new(@win).__js_call__("fetch", [url]).await

  def test_a_location_is_parsed_as_a_url
    response = fetch("/r-utf8")
    assert_equal(["http://localhost/%E6%97%A5%20x", true], [response.__js_get__("url"), response.__js_get__("redirected")])
    assert_equal("utf8", response.__js_call__("text", []).await)
  end

  # "http:done" against an http: URL is relative to it.
  def test_a_location_with_the_same_special_scheme_is_relative
    assert_equal("http://localhost/done", fetch("/r-scheme").__js_get__("url"))
  end

  def test_the_response_url_excludes_the_fragment
    assert_equal("http://localhost/done", fetch("/done#x").__js_get__("url"))
  end
end
