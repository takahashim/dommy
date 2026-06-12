# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Dommy::Resources — the single interface for resolving `<script src>` and fetch.
class TestResources < Minitest::Test
  def test_static_serves_string_body_by_path_and_url
    res = Dommy::Resources.static("/app.js" => "console.log(1)")

    by_path = res.get("/app.js")
    assert_equal 200, by_path.status
    assert_equal "console.log(1)", by_path.body
    assert by_path.success?

    by_url = res.get("http://example.test/app.js")
    assert_equal "console.log(1)", by_url.body
  end

  def test_static_serves_hash_entry_with_status_and_content_type
    res = Dommy::Resources.static("/data" => {"status" => 201, "content_type" => "application/json", "body" => "{}"})
    r = res.get("/data")

    assert_equal 201, r.status
    assert_equal "{}", r.body
    assert_equal "application/json", r.headers["Content-Type"]
  end

  def test_static_declines_unknown_url
    assert_nil Dommy::Resources.static("/a" => "x").get("/b")
  end

  def test_file_system_serves_under_base_url
    Dir.mktmpdir do |root|
      File.write(File.join(root, "app.js"), "FILE BODY")
      res = Dommy::Resources.file_system(root: root, base_url: "/assets")

      r = res.get("http://example.test/assets/app.js")
      assert_equal "FILE BODY", r.body

      assert_nil res.get("/assets/missing.js"), "missing file declines"
      assert_nil res.get("/other/app.js"), "outside base_url declines"
    end
  end

  def test_file_system_does_not_escape_root
    Dir.mktmpdir do |root|
      File.write(File.join(root, "secret"), "SECRET")
      res = Dommy::Resources.file_system(root: File.join(root, "public"), base_url: "/")
      Dir.mkdir(File.join(root, "public"))
      assert_nil res.get("/../secret")
    end
  end

  def test_chain_tries_in_order
    a = Dommy::Resources.static("/a" => "from-a")
    b = Dommy::Resources.static("/b" => "from-b")
    chain = Dommy::Resources.chain(a, b)

    assert_equal "from-a", chain.get("/a").body
    assert_equal "from-b", chain.get("/b").body
    assert_nil chain.get("/c")
  end

  def test_fetch_handler_maps_response_to_entry
    res = Dommy::Resources.static("/x" => {"status" => 200, "content_type" => "text/plain", "body" => "hi"})
    handler = Dommy::Resources::FetchHandler.new(res)

    entry = handler.call("/x", {"method" => "GET"})
    assert_equal 200, entry["status"]
    assert_equal "hi", entry["body"]
    assert_equal false, entry["redirected"]
  end

  def test_fetch_handler_declines_unknown_as_nil
    handler = Dommy::Resources::FetchHandler.new(Dommy::Resources.static({}))
    assert_nil handler.call("/missing", nil)
  end
end
