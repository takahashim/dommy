# frozen_string_literal: true

require "test_helper"
require "support/null_runtime"

class Dommy::Rack::TestNavigation < Minitest::Test
  include RackTestHelper

  def test_visit_about_blank_installs_a_blank_document_without_hitting_the_app
    app = ->(_env) { raise "the app must not be called for about: URLs" }
    session = Dommy::Rack::Session.new(app)
    session.visit("about:blank")
    assert_equal "about:blank", session.current_url
    assert_nil session.at_css("body *")
  end

  def test_visit_resolves_relative_url_against_default_host
    session = Dommy::Rack::Session.new(app_for("GET /posts" => html_response("<h1>Posts</h1>")))
    session.visit("/posts")
    assert_equal "http://example.org/posts", session.current_url
    assert_equal "/posts", session.current_path
    assert_equal "example.org", session.current_host
  end

  def test_visit_non_ascii_url_percent_encodes_it
    # A link with raw UTF-8 (note.com/hashtag/応援) must not crash the ASCII-only
    # URI parser — it is percent-encoded before the request, like a browser.
    session = Dommy::Rack::Session.new(
      app_for("GET /hashtag/%E5%BF%9C%E6%8F%B4" => html_response("<h1>応援</h1>"))
    )
    session.visit("http://example.org/hashtag/応援")
    assert_equal "http://example.org/hashtag/%E5%BF%9C%E6%8F%B4", session.current_url
    assert_equal "応援", session.at_css("h1").text_content
  end

  def test_follows_302_redirect_as_get
    app = app_for(
      "POST /posts" => [302, {"Location" => "/posts/1"}, []],
      "GET /posts/1" => html_response("<p>Created</p>")
    )
    session = Dommy::Rack::Session.new(app)
    session.post("/posts", params: {"title" => "x"})
    assert_equal "/posts/1", session.current_path
    assert_equal "Created", session.at_css("p").text_content
  end

  def test_307_preserves_method_and_body
    seen = []
    app = app_for(
      "POST /a" => [307, {"Location" => "/b"}, []],
      "POST /b" => ->(req) {
        seen << req.params["k"]
        html_response("<p>ok</p>")
      }
    )
    session = Dommy::Rack::Session.new(app)
    session.post("/a", params: {"k" => "v"})
    assert_equal ["v"], seen
  end

  # A form's `_method` override goes out as a POST from a browser, so a
  # 301/302/303 is followed with a GET (Rails' resources route a PUT to the
  # redirect target nowhere); a 307 keeps the method and the params.
  def override_app(status, seen, javascript: false)
    form = '<form method="post" action="/thing"><input type="hidden" name="_method" value="put">' \
           '<input name="k" value="v"><button>Save</button></form>'
    app = app_for(
      "GET /form" => html_response(form),
      "PUT /thing" => [status, {"Location" => "/done"}, []],
      "GET /done" => html_response("<p>done</p>"),
      "PUT /done" => ->(req) {
        seen << req.params
        html_response("<p>done</p>")
      }
    )
    Dommy::Rack::Session.new(app, javascript: javascript)
  end

  def test_a_method_override_form_follows_a_redirect_with_get
    [301, 302, 303].each do |status|
      seen = []
      session = override_app(status, seen)
      session.visit("/form")
      session.click_button("Save")
      assert_equal [200, "/done", []], [session.status, session.current_path, seen], "status #{status}"
    end
  end

  def test_a_method_override_form_keeps_its_method_through_a_307
    seen = []
    session = override_app(307, seen)
    session.visit("/form")
    session.click_button("Save")
    assert_equal [{"k" => "v"}], seen
  end

  # With JavaScript the page submits the form (its navigation delegate),
  # which resolves the override on its own path.
  def test_a_method_override_form_the_page_submits_follows_a_redirect_with_get
    previous_factory = DommyRackTestSupport::NullRuntimeBackend.install
    seen = []
    session = override_app(302, seen, javascript: true)
    session.visit("/form")
    session.click_button("Save")
    assert_equal [200, "/done", []], [session.status, session.current_path, seen]
  ensure
    session&.dispose
    DommyRackTestSupport::NullRuntimeBackend.restore(previous_factory)
  end

  # A PUT that really is one keeps its method through a 302, as Fetch has it.
  def test_a_put_keeps_its_method_through_a_302
    seen = []
    app = app_for(
      "PUT /thing" => [302, {"Location" => "/done"}, []],
      "PUT /done" => ->(req) {
        seen << req.request_method
        html_response("<p>done</p>")
      }
    )
    session = Dommy::Rack::Session.new(app)
    session.put("/thing")
    assert_equal ["PUT"], seen
  end

  def test_raises_on_too_many_redirects
    app = app_for("GET /loop" => [302, {"Location" => "/loop"}, []])
    session = Dommy::Rack::Session.new(app, max_redirects: 3)
    assert_raises(Dommy::Rack::TooManyRedirectsError) { session.visit("/loop") }
  end

  def test_cross_origin_navigation_raises
    session = Dommy::Rack::Session.new(app_for({}))
    assert_raises(Dommy::Rack::CrossOriginError) { session.visit("http://evil.com/") }
  end

  def test_back_and_forward
    app = app_for(
      "GET /one" => html_response("<h1>One</h1>"),
      "GET /two" => html_response("<h1>Two</h1>")
    )
    session = Dommy::Rack::Session.new(app)
    session.visit("/one")
    session.visit("/two")
    assert_equal "/two", session.current_path

    session.back
    assert_equal "/one", session.current_path
    assert_equal "One", session.at_css("h1").text_content

    session.forward
    assert_equal "/two", session.current_path
    assert_equal "Two", session.at_css("h1").text_content
  end

  def test_reload_refetches_current_url
    count = 0
    app = app_for("GET /x" => ->(_req) {
      count += 1
      html_response("<p>#{count}</p>")
    })
    session = Dommy::Rack::Session.new(app)
    session.visit("/x")
    session.reload
    assert_equal "2", session.at_css("p").text_content
  end
end
