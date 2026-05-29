# frozen_string_literal: true

require "test_helper"

class Dommy::Rack::TestResponse < Minitest::Test
  def build(status, headers, body, url: "http://example.org/")
    Dommy::Rack::Response.new(status, headers, body, url: url)
  end

  def test_exposes_status_and_body
    res = build(200, {"Content-Type" => "text/html"}, ["<h1>Hi</h1>"])
    assert_equal 200, res.status
    assert_equal "<h1>Hi</h1>", res.body
  end

  def test_drains_array_body_into_string
    res = build(200, {"Content-Type" => "text/html"}, ["a", "b", "c"])
    assert_equal "abc", res.body
  end

  def test_content_type_strips_parameters
    res = build(200, {"Content-Type" => "text/html; charset=utf-8"}, ["x"])
    assert_equal "text/html", res.content_type
  end

  def test_html_predicate
    assert build(200, {"Content-Type" => "text/html"}, ["x"]).html?
    refute build(200, {"Content-Type" => "application/json"}, ["{}"]).html?
  end

  def test_parses_html_document
    res = build(200, {"Content-Type" => "text/html"}, ["<h1>Title</h1>"])
    assert_equal "Title", res.document.query_selector("h1").text_content
  end

  def test_non_html_has_no_document
    res = build(200, {"Content-Type" => "text/plain"}, ["plain"])
    assert_nil res.document
  end

  def test_configures_document_url
    res = build(200, {"Content-Type" => "text/html"}, ["<p>x</p>"], url: "http://example.org/posts/1")
    assert_equal "http://example.org/posts/1", res.document.url
    assert_equal "http://example.org", res.document.origin
  end

  def test_sets_document_content_type
    res = build(200, {"Content-Type" => "text/html; charset=utf-8"}, ["<p>x</p>"])
    assert_equal "text/html", res.document.content_type
  end

  def test_json_predicate
    assert build(200, {"Content-Type" => "application/json"}, ["{}"]).json?
    assert build(200, {"Content-Type" => "text/json"}, ["{}"]).json?
    assert build(200, {"Content-Type" => "application/vnd.api+json"}, ["{}"]).json?
    refute build(200, {"Content-Type" => "text/html"}, ["x"]).json?
    refute build(200, {}, ["x"]).json?
  end

  def test_json_parses_body
    res = build(200, {"Content-Type" => "application/json"}, ['{"a":1,"b":[2,3]}'])
    assert_equal({"a" => 1, "b" => [2, 3]}, res.json)
  end

  def test_json_symbolize_names
    res = build(200, {"Content-Type" => "application/json"}, ['{"a":1}'])
    assert_equal({a: 1}, res.json(symbolize_names: true))
  end

  def test_json_parses_regardless_of_content_type
    res = build(200, {"Content-Type" => "text/plain"}, ['{"ok":true}'])
    assert_equal({"ok" => true}, res.json)
  end

  def test_json_raises_on_invalid_body
    res = build(200, {"Content-Type" => "application/json"}, ["not json"])
    assert_raises(JSON::ParserError) { res.json }
  end

  def test_redirect_predicate_and_location_header
    res = build(302, {"Location" => "/next"}, [])
    assert res.redirect?
    assert_equal "/next", res.location_header
  end

  def test_status_class_predicates
    ok = build(200, {}, [])
    assert ok.success?
    refute ok.error?

    missing = build(404, {}, [])
    assert missing.not_found?
    assert missing.client_error?
    assert missing.error?
    refute missing.success?

    boom = build(503, {}, [])
    assert boom.server_error?
    assert boom.error?
  end

  def test_case_insensitive_header_lookup
    res = build(302, {"location" => "/lower"}, [])
    assert_equal "/lower", res.location_header
  end

  def test_set_cookie_strings_handles_array
    res = build(200, {"Set-Cookie" => ["a=1", "b=2"]}, ["x"])
    assert_equal ["a=1", "b=2"], res.set_cookie_strings
  end

  def test_set_cookie_strings_handles_newline_joined_string
    res = build(200, {"Set-Cookie" => "a=1\nb=2"}, ["x"])
    assert_equal ["a=1", "b=2"], res.set_cookie_strings
  end
end
