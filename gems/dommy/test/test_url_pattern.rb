# frozen_string_literal: true

require_relative "test_helper"

class TestURLPattern < Minitest::Test
  include DommyTestHelper

  U = Dommy::Bridge::UNDEFINED

  def pattern(*args, **options)
    Dommy::URLPattern.new(*args, **options)
  end

  def groups(result, component)
    result[component]["groups"]
  end

  # --- construction ---------------------------------------------------------

  def test_init_leaves_missing_components_as_wildcards
    p = pattern({pathname: "/users/:id"})
    assert_equal("*", p.protocol)
    assert_equal("*", p.hostname)
    assert_equal("*", p.port)
    assert_equal("/users/:id", p.pathname)
    assert_equal("*", p.search)
    assert_equal("*", p.hash)
  end

  def test_empty_init_matches_everything
    assert(pattern.test("https://example.com/anything?q#h"))
    assert(pattern({}).test("data:text/plain,hi"))
  end

  def test_constructor_string_splits_into_components
    p = pattern("https://:sub.example.com:8080/books/:id/edit?q=:q#:frag")
    assert_equal("https", p.protocol)
    assert_equal(":sub.example.com", p.hostname)
    assert_equal("8080", p.port)
    assert_equal("/books/:id/edit", p.pathname)
    assert_equal("q=:q", p.search)
    assert_equal(":frag", p.hash)
    assert_equal("*", p.username)
    assert_equal("*", p.password)
  end

  def test_constructor_string_defaults_later_components_to_wildcards
    p = pattern("https://example.com")
    assert_equal("", p.port) # a hostname without a port means the default port
    assert_equal("*", p.pathname)
    assert_equal("*", p.search)
    assert_equal("*", p.hash)
    assert(p.test("https://example.com/any/thing?q"))
    refute(p.test("https://example.com:8443/"))
    assert(pattern("https://example.com/*").test("https://example.com/a/b?x#y"))
  end

  def test_constructor_string_fills_the_components_it_skips
    p = pattern("https://example.com?q")
    assert_equal("/", p.pathname) # the pathname of a special scheme
    assert_equal("q", p.search)
    assert_equal("*", p.hash)
    p = pattern("https://example.com#h")
    assert_equal("", p.search)
    assert_equal("h", p.hash)
    p = pattern("foo://bar#h")
    assert_equal("", p.pathname) # not special: no slash is assumed
  end

  def test_a_question_mark_after_a_name_is_its_modifier
    p = pattern("https://example.com/books/:id?q")
    assert_equal("/books/:id?q", p.pathname)
    assert_equal("*", p.search)
  end

  def test_constructor_string_with_credentials_and_ipv6
    # The colons of the credentials and of an IPv6 literal are escaped, or
    # they would read as names.
    p = pattern("https://user\\:pw@[\\:\\:1]:8443/p")
    assert_equal("user", p.username)
    assert_equal("pw", p.password)
    assert_equal("[\\:\\:1]", p.hostname)
    assert_equal("8443", p.port)
    assert(p.test("https://user:pw@[::1]:8443/p"))
    assert_raises(Dommy::Bridge::TypeError) { pattern("https://[::1]/") }
  end

  def test_constructor_string_treats_a_colon_inside_a_group_as_text
    p = pattern("https://example.com/{a:b}")
    assert_equal("/{a:b}", p.pathname)
    assert_equal("example.com", p.hostname)
    assert_equal("", p.port)
    assert_equal("x", groups(p.exec("https://example.com/ax"), "pathname")["b"])
  end

  def test_relative_constructor_string_needs_a_base_url
    p = pattern("/books/:id", "https://example.com/dir/page")
    assert_equal("https", p.protocol)
    assert_equal("example.com", p.hostname)
    assert_equal("/books/:id", p.pathname)
    assert_equal("*", p.search)
    assert_equal("*", p.hash)
    error = assert_raises(Dommy::Bridge::TypeError) { pattern("/books/:id") }
    assert_includes(error.message, "base URL")
  end

  def test_a_base_url_does_not_go_with_an_init
    assert_raises(Dommy::Bridge::TypeError) { pattern({pathname: "/x"}, "https://example.com") }
  end

  def test_relative_pathname_in_init_resolves_against_the_base_url_directory
    p = pattern({pathname: "b", baseURL: "https://example.com/foo/bar"})
    assert_equal("/foo/b", p.pathname)
    assert_equal("example.com", p.hostname)
    p = pattern({pathname: "/abs", baseURL: "https://example.com/foo/bar"})
    assert_equal("/abs", p.pathname)
  end

  def test_base_url_components_are_escaped_as_pattern_text
    p = pattern({hash: "x", baseURL: "https://example.com/a+b?q=(1)"})
    assert_equal("/a\\+b", p.pathname)
    assert_equal("q=\\(1\\)", p.search)
    assert(p.test("https://example.com/a+b?q=(1)#x"))
  end

  def test_a_component_in_the_init_stops_inheritance_from_the_base_url
    p = pattern({pathname: "/x", baseURL: "https://example.com:8080/y?q#h"})
    assert_equal("https", p.protocol)
    assert_equal("example.com", p.hostname)
    assert_equal("8080", p.port)
    assert_equal("*", p.search)
    assert_equal("*", p.hash)
    p = pattern({hostname: "other.test", baseURL: "https://example.com:8080/y"})
    assert_equal("*", p.port)
    assert_equal("*", p.pathname)
  end

  def test_symbol_keys_and_nil_members_in_a_ruby_init
    p = pattern({pathname: "/a", search: nil})
    assert_equal("/a", p.pathname)
    assert_equal("*", p.search)
  end

  def test_url_object_as_init
    url = Dommy::URL.new("https://example.com/a?b#c")
    p = pattern(url)
    assert_equal("https", p.protocol)
    assert_equal("/a", p.pathname)
    assert_equal("b", p.search)
    assert_equal("c", p.hash)
  end

  def test_default_port_of_a_special_scheme_is_the_empty_string
    assert_equal("", pattern({protocol: "https", port: "443"}).port)
    assert_equal("443", pattern({protocol: "http", port: "443"}).port)
    assert_equal("", pattern("https://example.com:443/").port)
  end

  # --- pattern strings are normalized --------------------------------------

  def test_getters_return_the_normalized_pattern_string
    assert_equal("/foo/*", pattern({pathname: "/foo/(.*)"}).pathname)
    assert_equal("/foo/bar", pattern({pathname: "/foo{/bar}"}).pathname)
    assert_equal("{:foo}bar", pattern({pathname: ":foo\\bar"}).pathname)
    assert_equal("/foo%7B", pattern({pathname: "/foo\\{"}).pathname)
    assert_equal("http{s}?", pattern({protocol: "http{s}?:"}).protocol)
    assert_equal("bar", pattern({search: "?bar"}).search)
    assert_equal("baz", pattern({hash: "#baz"}).hash)
  end

  def test_fixed_text_is_canonicalized_per_component
    assert_equal("/caf%C3%A9", pattern({pathname: "/caf\u00e9"}).pathname)
    assert_equal("/bar", pattern({pathname: "/foo/../bar"}).pathname)
    assert_equal("xn--caf-dma.com", pattern({hostname: "caf\u00e9.com"}).hostname)
    assert_equal("[\\:\\:ab\\::num]", pattern({hostname: "[\\:\\:AB\\::num]"}).hostname)
    assert_equal("http", pattern({protocol: "HTTP"}).protocol)
    assert_equal("q=caf%C3%A9", pattern({search: "q=caf\u00e9"}).search)
    assert_equal("caf%C3%A9", pattern({hash: "caf\u00e9"}).hash)
    assert_equal("caf%C3%A9", pattern({username: "caf\u00e9"}).username)
    assert_equal("80", pattern({port: "80 "}).port)
  end

  def test_opaque_pathname_for_a_non_special_scheme
    p = pattern({protocol: "data", pathname: "text/plain,a b"})
    assert_equal("text/plain,a b", p.pathname)
    assert(p.test("data:text/plain,a b"))
    assert_equal("/a%20b", pattern({protocol: "https", pathname: "/a b"}).pathname)
  end

  def test_canonicalization_failures_are_type_errors
    assert_raises(Dommy::Bridge::TypeError) { pattern({hostname: "bad hostname"}) }
    assert_raises(Dommy::Bridge::TypeError) { pattern({hostname: "bad\\:hostname"}) }
    assert_raises(Dommy::Bridge::TypeError) { pattern({port: "100000"}) }
    assert_raises(Dommy::Bridge::TypeError) { pattern({protocol: "1abc"}) }
    assert_raises(Dommy::Bridge::TypeError) { pattern({hostname: "{[\\:\\:f\u00e9\\::num]}"}) }
  end

  def test_pattern_syntax_errors_are_type_errors
    assert_raises(Dommy::Bridge::TypeError) { pattern({pathname: "/foo?"}) }     # a modifier with nothing to modify
    assert_raises(Dommy::Bridge::TypeError) { pattern({pathname: "/:id/:id"}) }  # a duplicate name
    assert_raises(Dommy::Bridge::TypeError) { pattern({pathname: "/(caf\u00e9)"}) } # a non-ASCII regexp
    assert_raises(Dommy::Bridge::TypeError) { pattern({pathname: "/()"}) }       # an empty regexp
    assert_raises(Dommy::Bridge::TypeError) { pattern({pathname: "/(\\m)"}) }    # a regexp ECMAScript rejects
    assert_raises(Dommy::Bridge::TypeError) { pattern({pathname: "/{a"}) }       # an unclosed group
    assert_raises(Dommy::Bridge::TypeError) { pattern({pathname: "/a\\"}) }      # a trailing escape
    assert_raises(Dommy::Bridge::TypeError) { pattern("(\\") }
  end

  def test_has_regexp_groups
    refute(pattern({pathname: "/a/:foo/:baz?/b/*"}).has_regexp_groups?)
    assert(pattern({pathname: "/a/:foo/:baz([a-z]+)?/b/*"}).has_regexp_groups?)
    refute(pattern({pathname: "/(.*)"}).has_regexp_groups?) # spelled like the wildcard it is
    assert(pattern({hostname: "(hi)"}).has_regexp_groups?)
  end

  # --- matching -------------------------------------------------------------

  def test_exec_reports_every_component
    result = pattern({pathname: "/users/:id"}).exec("https://x.test:8443/users/42?q=1#top")
    assert_equal(["https://x.test:8443/users/42?q=1#top"], result["inputs"])
    assert_equal({"input" => "https", "groups" => {"0" => "https"}}, result["protocol"])
    assert_equal({"input" => "x.test", "groups" => {"0" => "x.test"}}, result["hostname"])
    assert_equal({"input" => "8443", "groups" => {"0" => "8443"}}, result["port"])
    assert_equal({"input" => "/users/42", "groups" => {"id" => "42"}}, result["pathname"])
    assert_equal({"input" => "q=1", "groups" => {"0" => "q=1"}}, result["search"])
    assert_equal({"input" => "top", "groups" => {"0" => "top"}}, result["hash"])
  end

  def test_exec_returns_nil_when_a_component_does_not_match
    assert_nil(pattern({pathname: "/users/:id"}).exec("https://x.test/posts/42"))
    assert_nil(pattern({pathname: "/users/:id"}).exec("https://x.test/users/42/more"))
  end

  def test_a_relative_url_string_needs_a_base_url
    p = pattern({pathname: "/users/:id"})
    refute(p.test("/users/42"))
    assert(p.test("/users/42", "https://x.test"))
    result = p.exec("/users/42", "https://x.test")
    assert_equal(["/users/42", "https://x.test"], result["inputs"])
    refute(p.test("/users/42", "not a url"))
  end

  def test_exec_with_an_init_input
    p = pattern({pathname: "/users/:id"})
    result = p.exec({pathname: "/users/42"})
    assert_equal("42", groups(result, "pathname")["id"])
    assert_equal({"input" => "", "groups" => {"0" => ""}}, result["hostname"])
    assert_equal([{"pathname" => "/users/42"}], result["inputs"])
    result = p.exec({pathname: "users/42", baseURL: "https://x.test/dir/"})
    assert_nil(result) # resolved against the base URL's directory: /dir/users/42
    result = p.exec({pathname: "users/42", baseURL: "https://x.test/"})
    assert_equal("/users/42", result["pathname"]["input"])
    assert_equal("x.test", result["hostname"]["input"])
  end

  def test_exec_with_an_init_that_fails_to_canonicalize_is_a_miss_not_an_error
    assert_nil(pattern({port: "(.*)"}).exec({port: "invalid80"}))
    assert_nil(pattern.exec({baseURL: "not a url"}))
  end

  def test_exec_with_a_url_object
    url = Dommy::URL.new("https://x.test/users/42")
    result = pattern({pathname: "/users/:id"}).exec(url)
    assert_equal("42", groups(result, "pathname")["id"])
    assert_equal(["https://x.test/users/42"], result["inputs"])
  end

  def test_a_base_url_does_not_go_with_an_init_input
    assert_raises(Dommy::Bridge::TypeError) { pattern.exec({pathname: "/x"}, "https://x.test") }
  end

  def test_segment_wildcard_stops_at_the_separator
    p = pattern({pathname: "/blog/:title"})
    assert(p.test("https://x.test/blog/hello-world"))
    refute(p.test("https://x.test/blog/2012/02"))
    p = pattern({hostname: ":sub.example.com"})
    assert_equal("api", groups(p.exec("https://api.example.com/"), "hostname")["sub"])
    refute(p.test("https://a.b.example.com/"))
  end

  def test_modifiers_and_wildcards
    p = pattern({pathname: "/products/:id?"})
    assert(p.test("https://x.test/products"))
    assert(p.test("https://x.test/products/2"))
    refute(p.test("https://x.test/products/"))
    assert_nil(groups(p.exec("https://x.test/products"), "pathname")["id"])

    p = pattern({pathname: "/api/:version+"})
    assert_equal("v1/sub", groups(p.exec("https://x.test/api/v1/sub"), "pathname")["version"])
    refute(p.test("https://x.test/api"))

    p = pattern({pathname: "/docs/*"})
    assert_equal("a/b/c", groups(p.exec("https://x.test/docs/a/b/c"), "pathname")["0"])

    p = pattern({pathname: "/a/:b/:c*"})
    assert_equal("x/y", groups(p.exec("https://x.test/a/1/x/y"), "pathname")["c"])
  end

  def test_an_optional_wildcard_that_matches_nothing_is_undefined
    result = pattern({pathname: "*{}**?"}).exec({pathname: "foobar"})
    assert_equal({"0" => "foobar", "1" => nil}, groups(result, "pathname"))
  end

  def test_regexp_groups
    p = pattern({pathname: "/blog/:year(\\d+)/:month(\\d+)"})
    result = p.exec("https://x.test/blog/2012/02")
    assert_equal({"year" => "2012", "month" => "02"}, groups(result, "pathname"))
    refute(p.test("https://x.test/blog/twenty/02"))
    assert(pattern({pathname: "/([[a-z]--a])"}).test({pathname: "/z"}))
    refute(pattern({pathname: "/([[a-z]--a])"}).test({pathname: "/a"}))
    assert(pattern({protocol: "(data|javascript)"}).test("data:,x"))
  end

  def test_ignore_case
    assert(pattern({pathname: "/foo/bar"}, ignore_case: true).test("https://x.test/FOO/BAR"))
    refute(pattern({pathname: "/foo/bar"}).test("https://x.test/FOO/BAR"))
    p = pattern("https://example.com:8080/foo?bar#baz", ignore_case: true)
    assert(p.test({pathname: "/FOO", search: "BAR", hash: "BAZ", baseURL: "https://example.com:8080"}))
  end

  def test_matching_a_non_special_scheme
    # "data:text" would read as the name `:text`; the colon has to be escaped.
    p = pattern("data\\:text/plain,:body")
    assert_equal("hi", groups(p.exec("data:text/plain,hi"), "pathname")["body"])
    p = pattern({protocol: "javascript", pathname: "alert\\(:what\\)"})
    assert(p.test("javascript:alert(1)"))
  end

  # --- the JS bridge --------------------------------------------------------

  def test_js_constructor_overloads
    from_js = Dommy::URLPattern.method(:from_js)
    assert_equal("*", from_js.call([]).pathname)
    assert_equal("*", from_js.call([U, U]).pathname)
    assert_equal("*", from_js.call([nil]).pathname)
    assert_equal("/x", from_js.call([{"pathname" => "/x"}]).pathname)
    assert_equal("/x", from_js.call(["/x", "https://example.com"]).pathname)
    assert_equal("example.com", from_js.call(["/x", "https://example.com", {"ignoreCase" => true}]).hostname)
    assert(from_js.call(["/x", "https://example.com", {"ignoreCase" => true}]).test("https://example.com/X"))
    assert(from_js.call([{"pathname" => "/x"}, {"ignoreCase" => 1}]).test("https://example.com/X"))
    refute(from_js.call([{"pathname" => "/x"}, {"ignoreCase" => 0}]).test("https://example.com/X"))
    refute(from_js.call([{"pathname" => "/x"}, nil]).test("https://example.com/X"))
    assert_raises(Dommy::Bridge::TypeError) { from_js.call(["/x", {"ignoreCase" => true}, "https://example.com"]) }
    assert_raises(Dommy::Bridge::TypeError) { from_js.call(["/x", {"ignoreCase" => true}]) }
  end

  def test_js_dictionary_members_are_converted_to_strings
    p = Dommy::URLPattern.from_js([{"port" => 8080, "pathname" => U, "hostname" => "x.test"}])
    assert_equal("8080", p.port)
    assert_equal("*", p.pathname)
    p = Dommy::URLPattern.from_js([Dommy::URL.new("https://example.com/a?b#c")])
    assert_equal("/a", p.pathname)
    assert_equal("b", p.search)
    assert_raises(Dommy::Bridge::TypeError) { Dommy::URLPattern.from_js([Dommy::URL.new("https://example.org/%(")]) }
  end

  def test_js_exec_maps_missing_groups_to_undefined
    p = Dommy::URLPattern.from_js([{"pathname" => "/products/:id?"}])
    result = p.__js_call__("exec", ["https://x.test/products"])
    assert_same(U, result["pathname"]["groups"]["id"])
    assert_equal(["https://x.test/products"], result["inputs"])
    assert_nil(p.__js_call__("exec", ["https://x.test/other"]))
    assert_equal(true, p.__js_call__("test", ["/products/1", "https://x.test"]))
    assert_equal(false, p.__js_call__("test", ["/products/1", U]))
    assert_equal(false, p.__js_call__("test", [nil])) # null is an empty init, whose pathname is ""
    assert_equal(true, Dommy::URLPattern.from_js([]).__js_call__("test", [U]))
  end

  def test_js_getters
    p = Dommy::URLPattern.from_js([{"pathname" => "/a/(b)"}])
    assert_equal("/a/(b)", p.__js_get__("pathname"))
    assert_equal("*", p.__js_get__("protocol"))
    assert_equal(true, p.__js_get__("hasRegExpGroups"))
    assert_same(Dommy::Bridge::ABSENT, p.__js_get__("nope"))
  end

  def test_window_exposes_the_constructor
    win = make_window("<p></p>")
    ctor = win.__js_get__("URLPattern")
    pat = ctor.__js_new__([{"pathname" => "/x"}])
    assert_kind_of(Dommy::URLPattern, pat)
  end
end
