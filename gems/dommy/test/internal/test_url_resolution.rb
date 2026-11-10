# frozen_string_literal: true

require_relative "../test_helper"

# The URL-parser-backed helpers that took over from Ruby's URI library: a
# URL resolved against a base, a redirect's location URL, a URL without its
# fragment, an origin, and the path a resources adapter matches on.
class TestUrlResolution < Minitest::Test
  P = Dommy::Internal::UrlParser
  O = Dommy::Internal::Origin
  PATHING = Dommy::Resources::Pathing

  BASE = "http://a.test/dir/page?q=1#frag"

  # What RFC 3986's URI.join rejected or read otherwise, the URL parser reads
  # as a browser does.
  def test_resolve_is_the_url_parser
    assert_equal("http://a.test/%E6%97%A5%E6%9C%AC", P.resolve("/\u65E5\u672C", BASE))
    assert_equal("http://a.test/a%20b", P.resolve(" /a b ", BASE))
    assert_equal("http://a.test/dir/foo", P.resolve("http:foo", BASE))
    assert_equal("http://b.test/x", P.resolve("HTTP://B.Test:80/x", BASE))
    assert_equal("http://a.test/dir/page?q=1", P.resolve("", BASE))
    assert_nil(P.resolve("relative"))
    assert_nil(P.resolve("x", "not a url"))
  end

  def test_location_url_takes_the_request_fragment_when_it_has_none
    assert_equal("http://a.test/done#frag", P.location_url("/done", BASE))
    assert_equal("http://a.test/done#own", P.location_url("/done#own", BASE))
    # An empty fragment is a fragment: it is not replaced.
    assert_equal("http://a.test/done#", P.location_url("/done#", BASE))
    assert_equal("http://a.test/done", P.location_url("/done", "http://a.test/r"))
  end

  def test_location_url_reads_the_header_bytes_as_utf8
    assert_equal("http://a.test/%E6%97%A5#frag", P.location_url("/\u65E5".b, BASE))
    assert_nil(P.location_url("http://[", BASE))
  end

  def test_without_fragment
    assert_equal("http://a.test/dir/page?q=1", P.without_fragment(BASE))
    assert_equal("", P.without_fragment(""))
  end

  def test_origin_of_a_record
    assert_equal("https://a.test", O.of_url("https://a.test:443/x"))
    assert_equal("http://a.test:8080", O.of_url("http://a.test:8080/"))
    assert_equal("https://a.test", O.of_url("blob:https://a.test/uuid"))
    assert_equal("null", O.of_url("blob:ftp://a.test/uuid"))
    assert_equal("null", O.of_url("blob:/path"))
    assert_equal("null", O.of_url("file:///etc/hosts"))
    assert_equal("null", O.of_url("data:,x"))
    assert_equal("null", O.of_url("not a url"))
  end

  # Two opaque origins are never the same, so a same-origin check gets nil.
  def test_tuple_origin_of_a_url
    assert_equal("http://a.test", O.tuple_of_url("http://a.test/x"))
    assert_nil(O.tuple_of_url("data:,x"))
    assert_nil(O.tuple_of_url("not a url"))
  end

  def test_pathing_reads_a_url_or_a_bare_path
    assert_equal("/a%20b", PATHING.path_of("http://a.test/a b?x=1#f"))
    assert_equal("/api", PATHING.path_of("/api?x=1"))
    assert_equal("/search?q=hi", PATHING.path_with_query_of("http://a.test/search?q=hi#f"))
    assert_equal("/search", PATHING.path_with_query_of("/search"))
    assert_equal("/search?", PATHING.path_with_query_of("/search?"))
  end
end
