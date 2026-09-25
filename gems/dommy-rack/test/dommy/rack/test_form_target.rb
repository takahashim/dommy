# frozen_string_literal: true

require "test_helper"

# The browsing-context target (formtarget / target) is reported by the form
# serializer so a frame-capable host can honor it. dommy-rack has no frame
# model, so it only carries the value.
class Dommy::Rack::TestFormTarget < Minitest::Test
  def submit(html, submitter_selector: nil)
    form = Dommy.parse(html).document.query_selector("form")
    submitter = submitter_selector && form.query_selector(submitter_selector)
    config = Dommy::Rack::Session::Config.new(
      default_host: "http://example.org",
      follow_redirects: true,
      max_redirects: 5,
      respect_method_override: true,
      method_override_param: "_method",
      user_agent: "DommyRack",
      accept: "text/html"
    )
    Dommy::Rack::FormSubmission.new(form, submitter, config).submit!
  end

  def test_form_target_is_reported
    result = submit(<<~HTML)
      <form action="/x" method="post" target="_blank">
        <input type="text" name="a" value="1">
      </form>
    HTML
    assert_equal "_blank", result[:target]
  end

  def test_formtarget_on_the_submitter_wins
    result = submit(<<~HTML, submitter_selector: "button")
      <form action="/x" method="post" target="_blank">
        <button type="submit" formtarget="frame1">Go</button>
      </form>
    HTML
    assert_equal "frame1", result[:target]
  end
end
