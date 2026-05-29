# frozen_string_literal: true

require "test_helper"
require "tempfile"
require "tmpdir"

class Dommy::Rack::TestSession < Minitest::Test
  include RackTestHelper

  # The end-to-end example from the specification.
  def test_full_flow_visit_click_fill_submit
    app = app_for(
      "GET /" => html_response('<h1>Home</h1><a href="/posts/new">New post</a>'),
      "GET /posts/new" => html_response(
        '<form action="/posts" method="post">' \
        '<input type="text" name="post[title]">' \
        '<button type="submit">Create</button></form>'
      ),
      "POST /posts" => [302, {"Location" => "/posts/1"}, []],
      "GET /posts/1" => html_response('<p class="notice">Created</p>')
    )
    session = Dommy::Rack::Session.new(app)

    session.visit("/")
    session.click_link("New post")
    assert_equal "/posts/new", session.current_path

    session.fill_in("post[title]", with: "Hello")
    session.click_button("Create")

    assert_equal "/posts/1", session.current_path
    assert_equal "Created", session.at_css(".notice").text_content
  end

  def test_status_headers_body_html_text
    app = app_for("GET /" => html_response("<h1>Hi</h1>"))
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    assert_equal 200, session.status
    assert_equal "text/html", session.headers["Content-Type"]
    assert_equal "<h1>Hi</h1>", session.body
    assert_includes session.html, "<h1>Hi</h1>"
    assert_includes session.text, "Hi"
  end

  def test_cookie_persistence_across_requests
    app = app_for(
      "GET /set" => [200, {"Content-Type" => "text/html", "Set-Cookie" => "sid=42; path=/"}, ["<p>set</p>"]],
      "GET /show" => ->(req) { html_response("<p>#{req.cookies["sid"]}</p>") }
    )
    session = Dommy::Rack::Session.new(app)
    session.visit("/set")
    session.visit("/show")
    assert_equal "42", session.at_css("p").text_content
    assert_equal "42", session.get_cookie("sid")
  end

  def test_fetch_does_not_change_document_or_history
    app = app_for(
      "GET /page" => html_response("<h1>Page</h1>"),
      "GET /api" => [200, {"Content-Type" => "application/json"}, ['{"ok":true}']]
    )
    session = Dommy::Rack::Session.new(app)
    session.visit("/page")
    response = session.fetch("/api")

    assert_equal 200, response.status
    assert_equal '{"ok":true}', response.body
    # document and url unchanged by fetch
    assert_equal "/page", session.current_path
    assert_equal "Page", session.at_css("h1").text_content
  end

  def test_fetch_manual_returns_redirect_response
    app = app_for("GET /r" => [302, {"Location" => "/dest"}, []])
    session = Dommy::Rack::Session.new(app)
    response = session.fetch("/r", redirect: :manual)
    assert_equal 302, response.status
    assert_equal "/dest", response.location_header
  end

  def test_fetch_error_raises_on_redirect
    app = app_for("GET /r" => [302, {"Location" => "/dest"}, []])
    session = Dommy::Rack::Session.new(app)
    assert_raises(Dommy::Rack::Error) { session.fetch("/r", redirect: :error) }
  end

  def test_fill_in_by_placeholder_and_aria_label
    app = app_for("GET /" => html_response(
      '<form action="/x" method="post">' \
      '<input name="q" placeholder="Search">' \
      '<input name="city" aria-label="City">' \
      "</form>"
    ))
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    session.fill_in("Search", with: "ruby")
    session.fill_in("City", with: "Tokyo")
    assert_equal "ruby", session.at_css("[name='q']").value
    assert_equal "Tokyo", session.at_css("[name='city']").value
  end

  def test_dom_query_helpers
    app = app_for("GET /" => html_response('<ul><li class="x">a</li><li class="x">b</li></ul>'))
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    assert_equal "a", session.at_css(".x").text_content
    assert_equal 2, session.all_css(".x").length
    assert_equal "a", session.at_xpath("//li").text_content
    assert_equal 2, session.all_xpath("//li").length
  end

  def test_fill_in_by_label
    app = app_for("GET /" => html_response(
      '<form action="/x" method="post">' \
      '<label for="email">Email</label><input id="email" name="email" type="email">' \
      '</form>'
    ))
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    session.fill_in("Email", with: "a@b.com")
    assert_equal "a@b.com", session.at_css("#email").value
  end

  def test_check_and_choose
    app = app_for("GET /" => html_response(
      '<form action="/x" method="post">' \
      '<input type="checkbox" id="tos" name="tos" value="1">' \
      '<input type="radio" id="r1" name="plan" value="basic">' \
      '<input type="radio" id="r2" name="plan" value="pro">' \
      '</form>'
    ))
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    session.check("tos")
    session.choose("r2")
    assert session.at_css("#tos").checked
    assert session.at_css("#r2").checked
    refute session.at_css("#r1").checked
  end

  def test_click_link_missing_href_raises
    app = app_for("GET /" => html_response("<a>no href</a>"))
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    assert_raises(Dommy::Rack::ElementNotClickableError) { session.click_link("no href") }
  end

  def test_click_link_javascript_scheme_raises
    app = app_for("GET /" => html_response('<a href="javascript:void(0)">js</a>'))
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    assert_raises(Dommy::Rack::UnsupportedURLError) { session.click_link("js") }
  end

  def test_ambiguous_link_raises
    app = app_for("GET /" => html_response('<a href="/a">Dup</a><a href="/b">Dup</a>'))
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    assert_raises(Dommy::Rack::AmbiguousElementError) { session.click_link("Dup") }
  end

  def test_click_link_honors_base_href
    app = app_for(
      "GET /start" => html_response('<base href="/app/"><a href="page">Go</a>'),
      "GET /app/page" => html_response("<h1>Page</h1>")
    )
    session = Dommy::Rack::Session.new(app)
    session.visit("/start")
    session.click_link("Go")
    assert_equal "/app/page", session.current_path
    assert_equal "Page", session.at_css("h1").text_content
  end

  def test_document_exposes_content_type_and_origin
    app = app_for("GET /" => [200, {"Content-Type" => "text/html; charset=utf-8"}, ["<p>x</p>"]])
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    assert_equal "text/html", session.document.content_type
    assert_equal "http://example.org", session.document.origin
  end

  def test_file_upload_end_to_end
    tempfile = Tempfile.new(["up", ".txt"])
    tempfile.write("hello upload")
    tempfile.flush

    app = app_for(
      "GET /" => html_response(
        '<form action="/u" method="post" enctype="multipart/form-data">' \
        '<input type="file" name="doc"><button type="submit">Go</button></form>'
      ),
      "POST /u" => ->(req) {
        uploaded = req.params["doc"]
        html_response("<p id='r'>#{uploaded[:filename]}:#{uploaded[:tempfile].read}</p>")
      }
    )
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    session.attach_file("doc", tempfile.path)
    session.click_button("Go")

    assert_equal "#{File.basename(tempfile.path)}:hello upload", session.at_css("#r").text_content
  ensure
    tempfile&.close
    tempfile&.unlink
  end

  def test_attach_file_missing_path_raises
    app = app_for("GET /" => html_response(
      '<form action="/u" method="post" enctype="multipart/form-data"><input type="file" name="doc"></form>'
    ))
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    assert_raises(Dommy::Rack::FileNotFoundError) do
      session.attach_file("doc", "/no/such/file.txt")
    end
  end

  def test_click_image_button_submits_with_coordinates
    seen = nil
    app = app_for(
      "GET /" => html_response(
        '<form action="/s" method="post">' \
        '<input type="text" name="q" value="ruby">' \
        '<input type="image" name="go" src="/b.png" alt="Search"></form>'
      ),
      "POST /s" => ->(req) {
        seen = req.params
        html_response("<p>ok</p>")
      }
    )
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    session.click_button("Search")
    assert_equal "ruby", seen["q"]
    assert_equal "0", seen["go.x"]
    assert_equal "0", seen["go.y"]
  end

  def test_click_button_type_button_does_not_submit
    posted = false
    app = app_for(
      "GET /" => html_response('<form action="/x" method="post"><button type="button">Noop</button></form>'),
      "POST /x" => ->(_req) { posted = true; html_response("<p>posted</p>") }
    )
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    session.click_button("Noop")
    refute posted
    assert_equal "/", session.current_path
  end

  def test_click_link_element_by_css_selector
    app = app_for(
      "GET /" => html_response('<a class="next" href="/p2">More</a>'),
      "GET /p2" => html_response("<h1>P2</h1>")
    )
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    session.click_link_element(session.at_css("a.next"))
    assert_equal "/p2", session.current_path
    assert_equal "P2", session.at_css("h1").text_content
  end

  def test_post_json_sends_body_and_reads_response
    seen = {}
    app = app_for(
      "POST /api/posts" => ->(req) {
        seen[:content_type] = req.content_type
        seen[:accept] = req.get_header("HTTP_ACCEPT")
        seen[:body] = req.body.read
        [201, {"Content-Type" => "application/json"}, ['{"id":7}']]
      }
    )
    session = Dommy::Rack::Session.new(app)
    session.post_json("/api/posts", {title: "Hello"})

    assert_equal "application/json", seen[:content_type]
    assert_equal "application/json", seen[:accept]
    assert_equal({"title" => "Hello"}, JSON.parse(seen[:body]))
    assert_equal 201, session.status
    assert_equal({"id" => 7}, session.json)
    assert_equal({id: 7}, session.json(symbolize_names: true))
  end

  def test_post_json_accepts_pre_encoded_string
    seen = nil
    app = app_for("POST /api" => ->(req) {
      seen = req.body.read
      [200, {"Content-Type" => "application/json"}, ["{}"]]
    })
    session = Dommy::Rack::Session.new(app)
    session.post_json("/api", '{"raw":1}')
    assert_equal '{"raw":1}', seen
  end

  def test_json_request_helpers_use_their_verb
    method_seen = nil
    app = app_for(
      "PUT /api/1" => ->(req) { method_seen = req.request_method; [200, {"Content-Type" => "application/json"}, ["{}"]] },
      "PATCH /api/1" => ->(req) { method_seen = req.request_method; [200, {"Content-Type" => "application/json"}, ["{}"]] },
      "DELETE /api/1" => ->(req) { method_seen = req.request_method; [200, {"Content-Type" => "application/json"}, ["{}"]] }
    )
    session = Dommy::Rack::Session.new(app)
    session.put_json("/api/1", {})
    assert_equal "PUT", method_seen
    session.patch_json("/api/1", {})
    assert_equal "PATCH", method_seen
    session.delete_json("/api/1", {})
    assert_equal "DELETE", method_seen
  end

  def test_json_is_nil_before_any_request
    session = Dommy::Rack::Session.new(app_for({}))
    assert_nil session.json
  end

  # --- Persistent headers and auth ---

  def test_default_headers_sent_on_every_request
    seen = []
    app = app_for("GET /" => ->(req) { seen << req.get_header("HTTP_X_API_KEY"); html_response("<p>ok</p>") })
    session = Dommy::Rack::Session.new(app)
    session.set_header("X-API-Key", "secret")
    session.visit("/")
    session.visit("/")
    assert_equal %w[secret secret], seen
  end

  def test_per_request_header_overrides_default_case_insensitively
    seen = nil
    app = app_for("GET /" => ->(req) { seen = req.get_header("HTTP_X_TOKEN"); html_response("<p>ok</p>") })
    session = Dommy::Rack::Session.new(app)
    session.set_header("X-Token", "default")
    session.get("/", headers: {"x-token" => "override"})
    assert_equal "override", seen
  end

  def test_delete_header
    seen = :unset
    app = app_for("GET /" => ->(req) { seen = req.get_header("HTTP_X_TOKEN"); html_response("<p>ok</p>") })
    session = Dommy::Rack::Session.new(app)
    session.set_header("X-Token", "v").delete_header("x-token")
    session.visit("/")
    assert_nil seen
  end

  def test_basic_auth_and_bearer
    seen = nil
    app = app_for("GET /" => ->(req) { seen = req.get_header("HTTP_AUTHORIZATION"); html_response("<p>ok</p>") })
    session = Dommy::Rack::Session.new(app)
    session.basic_auth("alice", "pw")
    session.visit("/")
    assert_equal "Basic #{["alice:pw"].pack("m0")}", seen

    session.authorization_bearer("tok123")
    session.visit("/")
    assert_equal "Bearer tok123", seen
  end

  # --- Status predicates ---

  def test_status_predicates
    app = app_for(
      "GET /ok" => html_response("<p>ok</p>"),
      "GET /missing" => [404, {"Content-Type" => "text/html"}, ["<p>nope</p>"]],
      "GET /boom" => [500, {"Content-Type" => "text/html"}, ["<p>boom</p>"]]
    )
    session = Dommy::Rack::Session.new(app)
    session.visit("/ok")
    assert session.success?
    refute session.not_found?

    session.visit("/missing")
    assert session.not_found?
    assert session.client_error?
    refute session.success?

    session.visit("/boom")
    assert session.server_error?
  end

  # --- Redirect chain ---

  def test_redirect_chain_recorded
    app = app_for(
      "GET /a" => [302, {"Location" => "/b"}, []],
      "GET /b" => [302, {"Location" => "/c"}, []],
      "GET /c" => html_response("<p>done</p>")
    )
    session = Dommy::Rack::Session.new(app)
    session.visit("/a")
    assert session.redirected?
    assert_equal "/c", session.current_path
    assert_equal [302, 302], session.redirects.map { |r| r[:status] }
    assert_equal ["http://example.org/a", "http://example.org/b"], session.redirects.map { |r| r[:url] }
  end

  def test_no_redirects_for_direct_response
    app = app_for("GET /" => html_response("<p>x</p>"))
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    refute session.redirected?
    assert_empty session.redirects
  end

  # --- Meta refresh ---

  def test_follows_immediate_meta_refresh
    app = app_for(
      "GET /old" => html_response('<meta http-equiv="refresh" content="0; url=/new">'),
      "GET /new" => html_response("<h1>New</h1>")
    )
    session = Dommy::Rack::Session.new(app)
    session.visit("/old")
    assert_equal "/new", session.current_path
    assert_equal "New", session.at_css("h1").text_content
  end

  def test_meta_refresh_can_be_disabled
    app = app_for(
      "GET /old" => html_response('<meta http-equiv="refresh" content="0; url=/new">'),
      "GET /new" => html_response("<h1>New</h1>")
    )
    session = Dommy::Rack::Session.new(app, follow_meta_refresh: false)
    session.visit("/old")
    assert_equal "/old", session.current_path
  end

  def test_meta_refresh_ignores_nonzero_delay
    app = app_for("GET /old" => html_response('<meta http-equiv="refresh" content="5; url=/new">'))
    session = Dommy::Rack::Session.new(app)
    session.visit("/old")
    assert_equal "/old", session.current_path
  end

  # --- Scoping and matchers ---

  def test_within_scopes_finds
    app = app_for("GET /" => html_response(
      '<div id="a"><a href="/x">Go</a></div><div id="b"><a href="/y">Go</a></div>'
    ))
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    session.within("#b") do |s|
      s.click_link("Go")
    end
    assert_equal "/y", session.current_path
  end

  def test_within_restores_scope_after_block
    app = app_for("GET /" => html_response('<div id="a"><span>inside</span></div><span>outside</span>'))
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    session.within("#a") { |s| assert s.has_text?("inside") }
    assert session.has_text?("outside")
  end

  def test_matchers
    app = app_for("GET /" => html_response(
      '<p>hello world</p><a href="/x">Next</a><button>Save</button>' \
      '<input type="text" name="email"><span class="tag">t</span><span class="tag">t</span>'
    ))
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    assert session.has_text?("hello world")
    refute session.has_text?("missing")
    assert session.has_link?("Next")
    refute session.has_link?("Nope")
    assert session.has_button?("Save")
    assert session.has_field?("email")
    assert session.has_css?(".tag", count: 2)
    refute session.has_css?(".tag", count: 3)
    assert session.has_no_css?(".missing")
  end

  # --- iframe ---

  def test_within_frame
    app = app_for(
      "GET /" => html_response('<iframe id="f" src="/frame"></iframe>'),
      "GET /frame" => html_response("<h1>Inside frame</h1>")
    )
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    session.within_frame("f") do |s|
      assert s.has_text?("Inside frame")
    end
    # outer document unchanged
    assert_equal "/", session.current_path
  end

  # --- Instrumentation ---

  def test_request_and_response_hooks
    paths = []
    statuses = []
    app = app_for("GET /" => html_response("<p>x</p>"))
    session = Dommy::Rack::Session.new(app)
    session.on_request { |env| paths << env["PATH_INFO"] }
    session.on_response { |res| statuses << res.status }
    session.visit("/")
    assert_equal ["/"], paths
    assert_equal [200], statuses
  end

  # --- save_page ---

  def test_save_page
    app = app_for("GET /" => html_response("<h1>Saved</h1>"))
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    Dir.mktmpdir do |dir|
      path = File.join(dir, "out.html")
      assert_equal path, session.save_page(path)
      assert_includes File.read(path), "<h1>Saved</h1>"
    end
  end

  def test_rails_method_override_via_button
    method_seen = nil
    app = app_for(
      "GET /" => html_response(
        '<form action="/posts/1" method="post">' \
        '<input type="hidden" name="_method" value="delete">' \
        '<button type="submit">Destroy</button></form>'
      ),
      "DELETE /posts/1" => ->(req) {
        method_seen = req.request_method
        html_response("<p>gone</p>")
      }
    )
    session = Dommy::Rack::Session.new(app)
    session.visit("/")
    session.click_button("Destroy")
    assert_equal "DELETE", method_seen
    assert_equal "gone", session.at_css("p").text_content
  end
end
