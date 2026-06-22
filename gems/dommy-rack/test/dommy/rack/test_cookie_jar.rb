# frozen_string_literal: true

require "test_helper"

class Dommy::Rack::TestCookieJar < Minitest::Test
  def setup
    @jar = Dommy::Rack::CookieJar.new
  end

  def test_store_and_send_simple_cookie
    @jar.store_from_header("session=abc; path=/", "http://example.org/")
    assert_equal "session=abc", @jar.cookies_for("http://example.org/posts")
  end

  def test_get_returns_value
    @jar.store_from_header("token=xyz", "http://example.org/")
    assert_equal "xyz", @jar.get("token")
  end

  def test_path_scoping
    @jar.store_from_header("a=1; path=/admin", "http://example.org/admin")
    assert_equal "a=1", @jar.cookies_for("http://example.org/admin/users")
    assert_equal "", @jar.cookies_for("http://example.org/public")
  end

  def test_host_only_cookie_not_sent_to_other_host
    @jar.store_from_header("h=1", "http://example.org/")
    assert_equal "", @jar.cookies_for("http://other.org/")
  end

  def test_domain_cookie_matches_subdomain
    @jar.store_from_header("d=1; domain=example.org", "http://example.org/")
    assert_equal "d=1", @jar.cookies_for("http://www.example.org/")
  end

  def test_secure_cookie_only_over_https
    @jar.store_from_header("s=1; secure", "https://example.org/")
    assert_equal "", @jar.cookies_for("http://example.org/")
    assert_equal "s=1", @jar.cookies_for("https://example.org/")
  end

  def test_expired_cookie_via_max_age_is_removed
    @jar.store_from_header("e=1", "http://example.org/")
    @jar.store_from_header("e=1; Max-Age=0", "http://example.org/")
    assert_equal "", @jar.cookies_for("http://example.org/")
  end

  def test_replacing_cookie_with_same_name_path
    @jar.store_from_header("k=old; path=/", "http://example.org/")
    @jar.store_from_header("k=new; path=/", "http://example.org/")
    assert_equal "k=new", @jar.cookies_for("http://example.org/")
  end

  def test_more_specific_path_comes_first
    @jar.store_from_header("a=root; path=/", "http://example.org/")
    @jar.store_from_header("b=deep; path=/x", "http://example.org/x")
    assert_equal "b=deep; a=root", @jar.cookies_for("http://example.org/x/y")
  end

  def test_set_bang_and_clear
    @jar.set!("manual", "1", domain: "example.org")
    assert_equal "1", @jar.get("manual")
    @jar.clear
    assert_nil @jar.get("manual")
  end

  # The jar is shared between the page thread and network worker threads (the
  # async network path). Concurrent stores/reads must neither corrupt @entries
  # nor lose writes.
  def test_concurrent_stores_and_reads_are_safe
    threads = 50.times.map do |i|
      Thread.new do
        @jar.store_from_header("c#{i}=v#{i}; path=/", "http://example.org/")
        @jar.cookies_for("http://example.org/") # concurrent read
        @jar.get("c#{i}")
      end
    end
    threads.each(&:join)

    stored = @jar.cookies_for("http://example.org/")
    50.times { |i| assert_includes stored, "c#{i}=v#{i}", "cookie ##{i} survived the race" }
  end
end
class Dommy::Rack::TestCookieJarExport < Minitest::Test
  def setup
    @jar = Dommy::Rack::CookieJar.new
  end

  def test_export_import_round_trips_all_fields_including_host_only
    @jar.set!("sid", "secret", domain: ".hatena.ne.jp", path: "/", http_only: true) # host_only: false (domain given)
    @jar.set!("hostonly", "1", domain: nil, path: "/x") # host_only: true (no domain)
    exported = @jar.export
    assert_equal 2, exported.size

    fresh = Dommy::Rack::CookieJar.new
    fresh.import!(exported[0])
    fresh.import!(exported[1])
    by_name = fresh.all.to_h { |e| [e.name, e] }
    assert_equal "secret", by_name["sid"].value
    assert_equal false, by_name["sid"].host_only
    assert_equal true, by_name["hostonly"].host_only
    assert_equal "/x", by_name["hostonly"].path
  end

  def test_import_skips_an_expired_entry
    @jar.import!(name: "dead", value: "x", domain: "example.org", path: "/", expires: Time.now - 60)
    assert_empty @jar.all
  end

  def test_import_accepts_string_keys_too
    @jar.import!("name" => "k", "value" => "v", "domain" => "example.org", "path" => "/")
    assert_equal "v", @jar.get("k")
  end
end
