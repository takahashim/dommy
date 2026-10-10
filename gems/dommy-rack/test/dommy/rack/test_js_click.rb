# frozen_string_literal: true

require "test_helper"
require "support/null_runtime"

# With JavaScript, click_button and click_link are clicks the page handles:
# its listeners see them and can take the submission or the navigation over,
# as Turbo does; an un-prevented one submits or follows through the page.
class Dommy::Rack::TestJsClick < Minitest::Test
  include RackTestHelper

  PAGE = <<~HTML
    <form action="/save" method="post"><input name="title" value="x"><button>Save</button></form>
    <a href="/next">Next</a>
  HTML

  def setup
    @previous_factory = DommyRackTestSupport::NullRuntimeBackend.install
    @requests = []
    requests = @requests
    app = lambda do |env|
      requests << "#{env["REQUEST_METHOD"]} #{env["PATH_INFO"]}"
      [200, {"Content-Type" => "text/html"}, [env["PATH_INFO"] == "/" ? PAGE : "<h1>#{env["PATH_INFO"]}</h1>"]]
    end
    @session = Dommy::Rack::Session.new(app, javascript: true)
    @session.visit("/")
  end

  def teardown
    @session.dispose
    DommyRackTestSupport::NullRuntimeBackend.restore(@previous_factory)
  end

  def listen(type, &block)
    @session.document.add_event_listener(type, block)
  end

  def test_a_listener_sees_the_submit_and_can_take_it_over
    seen = []
    listen("submit") do |event|
      seen << event.__js_get__("submitter")&.text_content
      event.__js_call__("preventDefault", [])
    end

    @session.click_button("Save")

    assert_equal ["Save"], seen
    assert_equal ["GET /"], @requests
  end

  def test_an_unprevented_submit_navigates_through_the_page
    @session.click_button("Save")
    assert_equal ["GET /", "POST /save"], @requests
    assert_equal "/save", @session.current_path
  end

  def test_a_listener_can_take_a_link_over
    listen("click") { |event| event.__js_call__("preventDefault", []) }
    @session.click_link("Next")
    assert_equal ["GET /"], @requests
  end

  def test_an_unprevented_link_is_followed
    @session.click_link("Next")
    assert_equal "/next", @session.current_path
  end

  # A click returns the element clicked, with JavaScript or without; the
  # response is the session's last one.
  def test_a_click_returns_the_element
    button = @session.click_button("Save")
    assert_equal "Save", button.text_content
    assert_equal "/save", @session.current_path

    plain = Dommy::Rack::Session.new(@session.instance_variable_get(:@app))
    plain.visit("/")
    assert_equal "Next", plain.click_link("Next").text_content
    assert_equal 200, plain.last_response.status
    plain.visit("/")
    assert_equal "Save", plain.click_button("Save").text_content
    assert_equal "/save", plain.current_path
  end

  # A form the page submits is traced as one submitted from Ruby is.
  def test_a_form_the_page_submits_is_traced
    session = Dommy::Rack::Session.new(@session.instance_variable_get(:@app), javascript: true, trace: true)
    session.visit("/")
    session.click_button("Save")
    form = session.trace.forms.first
    assert_equal "x", form.data[:params]["title"]
    assert_equal "POST", form.data[:method]
  ensure
    session&.dispose
  end
end
