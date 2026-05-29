# frozen_string_literal: true

require_relative "test_helper"

# Covers Blob/File integration with fetch — body pass-through and
# automatic Content-Type derivation.
class TestFetchBlob < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    # Minimal stub: any URL succeeds with empty body
    @win.globals["__fetchy_stub__"] = {"/upload" => {"body" => "ok", "status" => 200}}
    @fetch = Dommy::FetchFn.new(@win)
  end

  def test_blob_body_is_passed_through
    blob = Dommy::Blob.new(["hello"], "type" => "text/plain")
    @fetch.__js_call__("fetch", ["/upload", {"body" => blob}])

    assert_same(blob, @win.globals["__last_body__"])
  end

  def test_blob_type_fills_in_content_type_header
    blob = Dommy::Blob.new(["data"], "type" => "application/pdf")
    @fetch.__js_call__("fetch", ["/upload", {"body" => blob}])

    headers = @win.globals["__last_init__"]["headers"]
    assert_equal("application/pdf", headers["Content-Type"])
  end

  def test_explicit_content_type_overrides_blob_type
    blob = Dommy::Blob.new(["data"], "type" => "application/pdf")
    @fetch.__js_call__(
      "fetch",
      [
        "/upload",
        {"body" => blob, "headers" => {"Content-Type" => "application/octet-stream"}}
      ]
    )

    headers = @win.globals["__last_init__"]["headers"]
    assert_equal("application/octet-stream", headers["Content-Type"])
  end

  def test_typeless_blob_does_not_add_content_type
    # no type
    blob = Dommy::Blob.new(["data"])
    @fetch.__js_call__("fetch", ["/upload", {"body" => blob}])

    headers = @win.globals["__last_init__"]["headers"]
    refute(headers.any? { |k, _| k.to_s.downcase == "content-type" })
  end

  def test_file_body_works_same_as_blob
    file = Dommy::File.new(["csv"], "report.csv", "type" => "text/csv")
    @fetch.__js_call__("fetch", ["/upload", {"body" => file}])

    assert_same(file, @win.globals["__last_body__"])
    assert_equal("text/csv", @win.globals["__last_init__"]["headers"]["Content-Type"])
  end

  def test_symbol_keyed_init_is_normalized_to_strings
    blob = Dommy::Blob.new(["x"], "type" => "text/plain")
    @fetch.__js_call__("fetch", ["/upload", {body: blob}])

    init = @win.globals["__last_init__"]
    assert_equal(blob, init["body"])
    assert_equal("text/plain", init["headers"]["Content-Type"])
  end

  def test_string_body_passes_through_unchanged
    @fetch.__js_call__("fetch", ["/upload", {"body" => "raw text", "headers" => {"X-Test" => "1"}}])

    init = @win.globals["__last_init__"]
    assert_equal("raw text", init["body"])
    assert_equal("1", init["headers"]["X-Test"])
  end
end
