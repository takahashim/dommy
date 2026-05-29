# frozen_string_literal: true

require "test_helper"

class Dommy::Rack::TestRequestBuilder < Minitest::Test
  def setup
    config = Dommy::Rack::Session::Config.new(
      default_host: "http://example.org",
      follow_redirects: true,
      max_redirects: 5,
      respect_method_override: true,
      method_override_param: "_method",
      user_agent: "DommyRack",
      accept: "text/html"
    )
    @builder = Dommy::Rack::RequestBuilder.new(config)
  end

  def test_basic_get_env
    env = @builder.build(method: "GET", url: "http://example.org/posts?page=2")
    assert_equal "GET", env["REQUEST_METHOD"]
    assert_equal "/posts", env["PATH_INFO"]
    assert_equal "page=2", env["QUERY_STRING"]
    assert_equal "example.org", env["SERVER_NAME"]
    assert_equal "80", env["SERVER_PORT"]
    assert_equal "http", env["rack.url_scheme"]
    assert_equal "example.org", env["HTTP_HOST"]
  end

  def test_default_headers_applied
    env = @builder.build(method: "GET", url: "http://example.org/")
    assert_equal "text/html", env["HTTP_ACCEPT"]
    assert_equal "DommyRack", env["HTTP_USER_AGENT"]
  end

  def test_header_normalization
    env = @builder.build(
      method: "GET", url: "http://example.org/",
      headers: {"X-Requested-With" => "XMLHttpRequest", "Accept" => "application/json"}
    )
    assert_equal "XMLHttpRequest", env["HTTP_X_REQUESTED_WITH"]
    assert_equal "application/json", env["HTTP_ACCEPT"]
  end

  def test_content_type_and_length_special_headers
    env = @builder.build(
      method: "POST", url: "http://example.org/",
      body: "raw", headers: {"Content-Type" => "text/plain"}
    )
    assert_equal "text/plain", env["CONTENT_TYPE"]
    assert_equal "3", env["CONTENT_LENGTH"]
  end

  def test_post_params_encoded_into_body
    env = @builder.build(method: "POST", url: "http://example.org/posts", params: {"title" => "Hi there"})
    body = env["rack.input"].read
    assert_equal "title=Hi+there", body
    assert_equal "application/x-www-form-urlencoded", env["CONTENT_TYPE"]
    assert_equal body.bytesize.to_s, env["CONTENT_LENGTH"]
  end

  def test_get_params_go_into_query_string
    env = @builder.build(method: "GET", url: "http://example.org/search?a=1", params: {"q" => "ruby"})
    assert_equal "a=1&q=ruby", env["QUERY_STRING"]
    assert_equal "", env["rack.input"].read
  end

  def test_cookie_string_sets_http_cookie
    env = @builder.build(method: "GET", url: "http://example.org/", cookie_string: "a=1; b=2")
    assert_equal "a=1; b=2", env["HTTP_COOKIE"]
  end

  def test_non_default_port_in_host_header
    env = @builder.build(method: "GET", url: "http://example.org:3000/")
    assert_equal "example.org:3000", env["HTTP_HOST"]
    assert_equal "3000", env["SERVER_PORT"]
  end

  def test_array_param_values
    env = @builder.build(method: "POST", url: "http://example.org/", params: {"tag" => %w[a b]})
    assert_equal "tag=a&tag=b", env["rack.input"].read
  end

  def test_params_and_body_together_raise
    assert_raises(ArgumentError) do
      @builder.build(method: "POST", url: "http://example.org/", params: {"a" => "1"}, body: "x")
    end
  end

  def test_file_param_produces_multipart_body
    file = Dommy::File.new(["hi there"], "a.txt", "type" => "text/plain")
    env = @builder.build(method: "POST", url: "http://example.org/u", params: {"title" => "T", "doc" => file})

    assert_match(%r{\Amultipart/form-data; boundary=}, env["CONTENT_TYPE"])
    body = env["rack.input"].read
    assert_includes body, %(Content-Disposition: form-data; name="title"\r\n\r\nT)
    assert_includes body, %(name="doc"; filename="a.txt")
    assert_includes body, "hi there"
    assert_equal body.bytesize.to_s, env["CONTENT_LENGTH"]
  end

  def test_get_form_with_file_uses_filename_in_query
    file = Dommy::File.new(["bytes"], "a.txt", "type" => "text/plain")
    env = @builder.build(method: "GET", url: "http://example.org/s", params: {"doc" => file})
    assert_equal "doc=a.txt", env["QUERY_STRING"]
  end
end
