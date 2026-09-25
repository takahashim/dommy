# frozen_string_literal: true

require_relative "test_helper"

# The core Fetcher serializes a form data set per its declared enctype, so the
# standalone Browser submits text/plain and multipart correctly (no Rack needed).
class TestNavigationFetcherFormEncoding < Minitest::Test
  # A Resources adapter that records the outgoing request and serves a stub.
  class Recording
    attr_reader :last

    def request(method:, url:, headers: {}, body: nil)
      @last = {method: method, url: url, headers: headers, body: body}
      Dommy::Resources::Response.new(status: 200, headers: {"Content-Type" => "text/html"}, body: "<html></html>", url: url)
    end
  end

  def setup
    @resources = Recording.new
    @fetcher = Dommy::Navigation::Fetcher.new(@resources)
  end

  def test_text_plain_enctype_sends_plain_text_body
    @fetcher.request(
      method: "POST", url: "http://example.org/x",
      params: [["title", "Hi there"], ["note", "a=b"]], enctype: "text/plain"
    )

    assert_equal "text/plain;charset=UTF-8", @resources.last[:headers]["Content-Type"]
    assert_equal "title=Hi there\r\nnote=a=b\r\n", @resources.last[:body]
  end

  def test_multipart_enctype_with_a_file_sends_a_file_part
    file = Dommy::File.new(["hello"], "a.txt", "type" => "text/plain")
    @fetcher.request(
      method: "POST", url: "http://example.org/u",
      params: [["title", "T"], ["doc", file]], enctype: "multipart/form-data"
    )

    type = @resources.last[:headers]["Content-Type"]
    assert_match(%r{\Amultipart/form-data; boundary=}, type)
    body = @resources.last[:body]
    assert_includes body, %(Content-Disposition: form-data; name="title"\r\n\r\nT)
    assert_includes body, %(name="doc"; filename="a.txt")
    assert_includes body, "hello"
  end

  def test_urlencoded_is_the_default_without_enctype
    @fetcher.request(method: "POST", url: "http://example.org/x", params: [["title", "Hi there"]])

    assert_equal "application/x-www-form-urlencoded", @resources.last[:headers]["Content-Type"]
    assert_equal "title=Hi+there", @resources.last[:body]
  end
end
