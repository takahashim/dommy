require "dommy/rails/minitest"
require "test_helper"

class TestMinitestAssertions < Minitest::Test
  include Dommy::TestHelpers
  include Dommy::Minitest::Assertions
  include Dommy::Rails::Minitest::Assertions
  include Dommy::Rails::Minitest::Integration

  def test_assert_dom_has_css_alias
    doc = parse_html("<h1>Articles</h1>")

    assert_dom_has_css(doc, "h1", text: "Articles")
    refute_dom_has_css(doc, "h2")
  end

  def test_assert_dom_has_text_alias
    doc = parse_html("<p>Saved article</p>")

    assert_dom_has_text(doc, "Saved")
    refute_dom_has_text(doc, "Deleted")
  end

  def test_assert_dom_has_xpath
    doc = parse_html("<section><h1>Articles</h1></section>")

    assert_dom_has_xpath(doc, "//h1", text: "Articles")
    refute_dom_has_xpath(doc, "//h2")
  end

  def test_assert_dom_has_title_meta_and_csrf
    doc = parse_html(<<~HTML)
      <!doctype html>
      <html>
        <head>
          <title>Articles</title>
          <meta name="description" content="Article index">
          <meta name="csrf-param" content="authenticity_token">
          <meta name="csrf-token" content="secret">
        </head>
        <body>
          <form><input type="hidden" name="authenticity_token" value="secret"></form>
        </body>
      </html>
    HTML

    assert_dom_has_title(doc, "Articles")
    assert_dom_has_meta(doc, name: "description", content: "Article index")
    assert_dom_has_csrf_meta_tags(doc)
    assert_dom_has_authenticity_token(doc)
  end

  def test_assert_dom_has_meta_requires_all_given_criteria
    doc = parse_html(<<~HTML)
      <head>
        <meta name="description" content="Article index">
        <meta property="og:title" content="Articles">
      </head>
    HTML

    assert_dom_has_meta(doc, property: "og:title", content: "Articles")
    refute_dom_has_meta(doc, name: "description", property: "og:title")
    refute_dom_has_meta(doc, name: "description", content: "Articles")
  end

  def test_assert_dom_has_link_normalizes_urls
    doc = parse_html('<a href="http://www.example.com/articles?bar=2&amp;foo=1">Articles</a>')

    assert_dom_has_link(doc, "Articles", href: "/articles?foo=1&bar=2")
  end

  def test_assert_dom_has_turbo_frame
    doc = parse_html('<turbo-frame id="comments"><p>Hello</p></turbo-frame>')

    assert_dom_has_turbo_frame(doc, "comments", text: "Hello") do |frame|
      assert_dom_has_css(frame, "p", text: "Hello")
    end
    refute_dom_has_turbo_frame(doc, "missing")
  end

  def test_assert_dom_has_select_and_checked_fields
    doc = parse_html(<<~HTML)
      <label for="status">Status</label>
      <select id="status" name="article[status]"><option>Draft</option></select>
      <input type="checkbox" name="article[published]" checked>
      <input type="checkbox" name="article[featured]">
    HTML

    assert_dom_has_select(doc, "article[status]", label: "Status")
    assert_dom_has_checked_field(doc, "article[published]")
    assert_dom_has_unchecked_field(doc, "article[featured]")
  end

  def test_assert_dom_has_form
    html = '<form action="http://www.example.com/articles?bar=2&amp;foo=1" method="post"><input type="text" name="article[title]"></form>'
    doc = parse_html(html)
    assert_dom_has_form(doc, action: "/articles?foo=1&bar=2")
  end

  def test_assert_dom_has_turbo_stream
    response = Struct.new(:body).new('<turbo-stream action="append" target="comments"><template><p>Comment</p></template></turbo-stream>')
    assert_dom_has_turbo_stream(response, action: "append", target: "comments")
    assert_dom_appends_turbo_stream(response, "comments")
    assert_dom_has_turbo_stream(response, action: "append", target: "comments") do |fragment|
      assert_dom_has_css(fragment, "p", text: "Comment")
    end
    assert_raises(Minitest::Assertion) { assert_dom_replaces_turbo_stream(response, "comments") }
  end

  def test_assert_dom_has_stimulus_controller
    html = '<div data-controller="dropdown"></div>'
    doc = parse_html(html)
    assert_dom_has_stimulus_controller(doc, "dropdown")
  end

  def test_assert_dom_has_stimulus_wiring
    html = <<~HTML
      <div data-controller="dropdown" data-dropdown-open-value="false">
        <button data-action="click->dropdown#toggle">Toggle</button>
        <div data-dropdown-target="menu"></div>
      </div>
    HTML
    doc = parse_html(html)

    assert_dom_has_stimulus_action(doc, "click->dropdown#toggle")
    assert_dom_has_stimulus_action(doc, "dropdown#toggle")
    assert_dom_has_stimulus_target(doc, "dropdown", "menu")
    assert_dom_has_stimulus_value(doc, "dropdown", "open", false)
  end

  def test_assert_dom_no_duplicate_ids
    html = '<div id="a"></div><div id="b"></div>'
    doc = parse_html(html)
    assert_dom_no_duplicate_ids(doc)
  end

  def test_assert_dom_no_empty_links
    doc = parse_html('<a href="/ok">OK</a><a href="/icon" aria-label="Icon"></a>')

    assert_dom_no_empty_links(doc)
  end

  def test_assert_dom_no_nested_interactive_elements
    doc = parse_html('<button>Save</button><a href="/edit">Edit</a>')

    assert_dom_no_nested_interactive_elements(doc)
  end

  def test_integration_dom_refreshes_when_response_body_changes
    response = Struct.new(:body).new("<h1>First</h1>")
    define_singleton_method(:response) { response }

    assert_equal "First", dom.query_selector("h1").text_content

    response.body = "<h1>Second</h1>"
    assert_equal "Second", dom.query_selector("h1").text_content
  end

  def test_integration_dom_falls_back_to_rendered
    define_singleton_method(:rendered) { "<p>Rendered</p>" }

    assert_equal "Rendered", dom.query_selector("p").text_content
  end
end
