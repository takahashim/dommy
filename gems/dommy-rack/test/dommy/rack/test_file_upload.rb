# frozen_string_literal: true

require "test_helper"

class Dommy::Rack::TestFileUpload < Minitest::Test
  def file(content, name, type)
    Dommy::File.new([content], name, "type" => type)
  end

  def test_multipart_false_for_text_params
    refute Dommy::Rack::FileUpload.multipart?([["a", "1"], ["b", "x"], ["b", "y"]])
  end

  def test_multipart_true_when_file_present
    pairs = [["doc", file("hi", "a.txt", "text/plain")]]
    assert Dommy::Rack::FileUpload.multipart?(pairs)
  end

  def test_multipart_true_for_repeated_name_with_file
    pairs = [["docs", "text"], ["docs", file("hi", "a.txt", "text/plain")]]
    assert Dommy::Rack::FileUpload.multipart?(pairs)
  end

  def test_encode_returns_body_and_content_type
    pairs = [["title", "Hello"], ["doc", file("data", "a.txt", "text/plain")]]
    body, content_type = Dommy::Rack::FileUpload.encode(pairs)

    assert_match(%r{\Amultipart/form-data; boundary=}, content_type)
    assert_includes body, %(Content-Disposition: form-data; name="title")
    assert_includes body, %(name="doc"; filename="a.txt")
    assert_includes body, "data"
    assert_equal Encoding::ASCII_8BIT, body.encoding
  end

  def test_multipart_false_for_nil
    refute Dommy::Rack::FileUpload.multipart?(nil)
  end

  def test_mime_type_for_known_extensions
    assert_equal "text/plain", Dommy::Rack::FileUpload.mime_type_for("/tmp/a.txt")
    assert_equal "image/jpeg", Dommy::Rack::FileUpload.mime_type_for("/tmp/PHOTO.JPG")
    assert_equal "application/json", Dommy::Rack::FileUpload.mime_type_for("data.json")
  end

  def test_mime_type_for_unknown_extension
    assert_equal "application/octet-stream", Dommy::Rack::FileUpload.mime_type_for("/tmp/a.xyz")
  end
end
