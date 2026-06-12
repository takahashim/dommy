require "test_helper"
require "dommy/rails/rspec"

class TestRSpecIntegration < Minitest::Test
  Response = Struct.new(:body)
  MailPart = Struct.new(:body)
  Mail = Struct.new(:html_part, :text_part, :body)

  class Context
    include Dommy::Rails::RSpec::Integration

    attr_accessor :response, :rendered, :message
  end

  def test_dom_helper_parses_response_body
    context = Context.new
    context.response = Response.new("<h1>Articles</h1>")

    assert context.have_css("h1", text: "Articles").matches?(context.dom)
  end

  def test_dom_helper_refreshes_when_response_body_changes
    context = Context.new
    context.response = Response.new("<h1>First</h1>")
    assert_equal "First", context.dom.query_selector("h1").text_content

    context.response.body = "<h1>Second</h1>"
    assert_equal "Second", context.dom.query_selector("h1").text_content
  end

  def test_dom_helper_falls_back_to_rendered
    context = Context.new
    context.rendered = "<p>Rendered view</p>"

    assert context.have_css("p", text: "Rendered view").matches?(context.dom)
  end

  def test_have_form_understands_method_override
    context = Context.new
    context.response = Response.new(<<~HTML)
      <form action="/articles/1" method="post">
        <input type="hidden" name="_method" value="patch">
      </form>
    HTML

    assert context.have_form(action: "/articles/1", method: :patch).matches?(context.dom)
    refute context.have_form(action: "/articles/1", method: :post).matches?(context.dom)
  end

  def test_have_form_normalizes_action_url
    context = Context.new
    context.response = Response.new('<form action="http://www.example.com/articles?bar=2&amp;foo=1" method="post"></form>')

    assert context.have_form(action: "/articles?foo=1&bar=2", method: :post).matches?(context.dom)
  end

  def test_page_matchers
    context = Context.new
    context.response = Response.new(<<~HTML)
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

    assert context.have_title("Articles").matches?(context.dom)
    assert context.have_meta(name: "description", content: "Article index").matches?(context.dom)
    assert context.have_csrf_meta_tags.matches?(context.dom)
    assert context.have_authenticity_token.matches?(context.dom)
    assert context.have_xpath("//title", text: "Articles").matches?(context.dom)
  end

  def test_have_link_normalizes_urls
    context = Context.new
    context.response = Response.new('<a href="http://www.example.com/articles?bar=2&amp;foo=1">Articles</a>')

    assert context.have_link("Articles", href: "/articles?foo=1&bar=2").matches?(context.dom)
  end

  def test_have_turbo_frame
    context = Context.new
    context.response = Response.new('<turbo-frame id="comments"><p>Hello</p></turbo-frame>')

    yielded = nil
    assert context.have_turbo_frame("comments", text: "Hello").matches?(context.dom) { |frame| yielded = frame }
    assert_equal "Hello", yielded.query_selector("p").text_content
    refute context.have_turbo_frame("missing").matches?(context.dom)
  end

  def test_field_matchers
    context = Context.new
    context.response = Response.new(<<~HTML)
      <label for="status">Status</label>
      <select id="status" name="article[status]"><option>Draft</option></select>
      <input type="checkbox" name="article[published]" checked>
      <input type="checkbox" name="article[featured]">
    HTML

    assert context.have_select("article[status]", label: "Status").matches?(context.dom)
    assert context.have_checked_field("article[published]").matches?(context.dom)
    assert context.have_unchecked_field("article[featured]").matches?(context.dom)
  end

  def test_have_turbo_stream_matches_response_body
    context = Context.new
    response = Response.new('<turbo-stream action="append" target="comments"><template><p>Comment</p></template></turbo-stream>')

    assert context.have_turbo_stream(action: "append", target: "comments").matches?(response)
    assert context.append_turbo_stream("comments").matches?(response)
    yielded = nil
    assert context.append_turbo_stream("comments").matches?(response) { |fragment| yielded = fragment }
    assert_equal "Comment", yielded.query_selector("p").text_content
    refute context.replace_turbo_stream("comments").matches?(response)
  end

  def test_have_stimulus_controller
    context = Context.new
    context.response = Response.new('<div data-controller="dropdown modal"></div>')

    assert context.have_stimulus_controller("dropdown").matches?(context.dom)
    refute context.have_stimulus_controller("tabs").matches?(context.dom)
  end

  def test_have_stimulus_wiring
    context = Context.new
    context.response = Response.new(<<~HTML)
      <div data-controller="dropdown" data-dropdown-open-value="false">
        <button data-action="click->dropdown#toggle">Toggle</button>
        <div data-dropdown-target="menu"></div>
      </div>
    HTML

    assert context.have_stimulus_action("click->dropdown#toggle").matches?(context.dom)
    assert context.have_stimulus_action("dropdown#toggle").matches?(context.dom)
    assert context.have_stimulus_target("dropdown", "menu").matches?(context.dom)
    assert context.have_stimulus_value("dropdown", "open", false).matches?(context.dom)
  end

  def test_lint_matchers
    context = Context.new
    context.response = Response.new(<<~HTML)
      <label for="title">Title</label>
      <input id="title" name="article[title]">
      <div id="description"></div>
      <p aria-describedby="description">Body</p>
      <a href="/ok">OK</a>
      <button>Save</button>
    HTML

    assert context.have_no_duplicate_ids.matches?(context.dom)
    assert context.have_no_invalid_aria_references.matches?(context.dom)
    assert context.have_no_missing_form_labels.matches?(context.dom)
    assert context.have_no_empty_links.matches?(context.dom)
    assert context.have_no_nested_interactive_elements.matches?(context.dom)
  end

  def test_mail_matchers
    context = Context.new
    mail = Mail.new(
      MailPart.new('<a href="http://www.example.com/confirm">Confirm your account</a>'),
      MailPart.new("Welcome. Confirm your account."),
      nil
    )

    assert context.have_html_link("Confirm your account", href: "/confirm").matches?(mail)
    assert context.have_html_text("Confirm your account").matches?(mail)
    assert context.have_plain_text("Welcome").matches?(mail)
  end
end
