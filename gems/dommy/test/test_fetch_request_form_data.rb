# frozen_string_literal: true

require_relative "test_helper"

class TestFetchRequestFormData < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<p></p>")
  end

  def request(body, content_type)
    Dommy::Request.new("http://example.test/submit",
                       {"method" => "POST", "body" => body, "headers" => {"content-type" => content_type}}, @win)
  end

  def test_form_data_parses_a_urlencoded_body
    form = request("a=1&b=%E3%81%82&c", "application/x-www-form-urlencoded").__js_call__("formData", []).await
    assert_kind_of(Dommy::FormData, form)
    assert_equal([["a", "1"], ["b", "\u3042"], ["c", ""]], form.entries.to_a)
  end

  def test_form_data_parses_a_multipart_body
    body = "--xyz\r\nContent-Disposition: form-data; name=\"k\"\r\n\r\nv\r\n--xyz--\r\n"
    form = request(body, "multipart/form-data; boundary=xyz").__js_call__("formData", []).await
    assert_equal([["k", "v"]], form.entries.to_a)
  end

  def test_form_data_rejects_another_content_type_and_a_used_body
    r = request("x", "text/plain")
    assert_raises(RuntimeError) { r.__js_call__("formData", []).await }
    r = request("a=1", "application/x-www-form-urlencoded")
    r.__js_call__("text", []).await
    assert_raises(RuntimeError) { r.__js_call__("formData", []).await }
  end
end
