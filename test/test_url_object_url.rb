# frozen_string_literal: true

require_relative "test_helper"

class TestURLObjectURL < Minitest::Test
  include DommyTestHelper

  def setup
    Dommy::URL.__reset_blob_urls__
  end

  # --- createObjectURL ---------------------------------------------

  def test_create_object_url_returns_blob_scheme_string
    blob = Dommy::Blob.new(["data"], "type" => "application/octet-stream")
    url = Dommy::URL.create_object_url(blob)
    assert_match(/\Ablob:/, url)
  end

  def test_create_object_url_returns_unique_url_per_call
    blob = Dommy::Blob.new(["x"])
    u1 = Dommy::URL.create_object_url(blob)
    u2 = Dommy::URL.create_object_url(blob)
    refute_equal(u1, u2)
  end

  def test_create_object_url_returns_nil_for_non_blob
    assert_nil(Dommy::URL.create_object_url("not a blob"))
    assert_nil(Dommy::URL.create_object_url(nil))
  end

  def test_create_object_url_accepts_file_subclass
    file = Dommy::File.new(["csv"], "data.csv", "type" => "text/csv")
    url = Dommy::URL.create_object_url(file)
    assert_kind_of(String, url)
    assert_same(file, Dommy::URL.__resolve_blob_url__(url))
  end

  # --- resolve back to blob ----------------------------------------

  def test_resolve_blob_url_returns_original_blob
    blob = Dommy::Blob.new(["hello"], "type" => "text/plain")
    url = Dommy::URL.create_object_url(blob)
    assert_same(blob, Dommy::URL.__resolve_blob_url__(url))
  end

  def test_resolve_blob_url_returns_nil_for_unknown
    assert_nil(Dommy::URL.__resolve_blob_url__("blob:dommy/unknown"))
  end

  # --- revokeObjectURL ---------------------------------------------

  def test_revoke_object_url_removes_registration
    blob = Dommy::Blob.new(["x"])
    url = Dommy::URL.create_object_url(blob)
    Dommy::URL.revoke_object_url(url)
    assert_nil(Dommy::URL.__resolve_blob_url__(url))
  end

  def test_revoke_object_url_is_idempotent
    # no raise
    Dommy::URL.revoke_object_url("blob:dommy/unknown")
  end

  # --- Camel-case aliases (JS-style) -------------------------------

  def test_camel_case_create_alias
    blob = Dommy::Blob.new(["x"])
    assert_kind_of(String, Dommy::URL.createObjectURL(blob))
  end

  def test_camel_case_revoke_alias
    blob = Dommy::Blob.new(["x"])
    url = Dommy::URL.createObjectURL(blob)
    Dommy::URL.revokeObjectURL(url)
    assert_nil(Dommy::URL.__resolve_blob_url__(url))
  end

  # --- Window / JS bridge ------------------------------------------

  def test_window_url_constructor_exposes_create_object_url
    win = make_window
    url_ctor = win.__js_get__("URL")
    blob = Dommy::Blob.new(["hi"], "type" => "text/plain")
    url = url_ctor.__js_call__("createObjectURL", [blob])
    assert_match(/\Ablob:/, url)
    assert_same(blob, Dommy::URL.__resolve_blob_url__(url))
  end

  def test_window_url_constructor_exposes_revoke_object_url
    win = make_window
    url_ctor = win.__js_get__("URL")
    blob = Dommy::Blob.new(["x"])
    url = url_ctor.__js_call__("createObjectURL", [blob])
    url_ctor.__js_call__("revokeObjectURL", [url])
    assert_nil(Dommy::URL.__resolve_blob_url__(url))
  end

  def test_window_url_constructor_still_creates_url_instances
    win = make_window
    url_ctor = win.__js_get__("URL")
    u = url_ctor.__js_new__(["https://x.test/a/b"])
    assert_kind_of(Dommy::URL, u)
    assert_equal("https://x.test/a/b", u.__js_get__("href"))
  end
end
