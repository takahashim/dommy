# frozen_string_literal: true

require "test_helper"

# External <link rel=stylesheet> CSS is fetched and filled on navigation when
# load_stylesheets is on (the default for browser specs / javascript: true),
# so class-based visibility matches the browser. Off for plain rack_test.
class Dommy::Rack::TestStylesheetLoading < Minitest::Test
  include RackTestHelper

  def css_response(css)
    [200, {"Content-Type" => "text/css"}, [css]]
  end

  def app
    app_for(
      "GET /page" => html_response(
        '<link rel="stylesheet" href="/app.css"><p id="x" class="hidden">x</p>'
      ),
      "GET /app.css" => css_response(".hidden { display: none }")
    )
  end

  def test_link_css_applies_when_enabled
    session = Dommy::Rack::Session.new(app, load_stylesheets: true)
    session.visit("/page")
    refute Dommy::Rack.visible?(session.at_css("#x"))
  end

  def test_link_css_ignored_by_default_rack_test
    session = Dommy::Rack::Session.new(app)
    session.visit("/page")
    assert Dommy::Rack.visible?(session.at_css("#x"))
  end

  def test_default_follows_javascript_flag
    refute Dommy::Rack::Session.new(app).load_stylesheets?
    # An unset load_stylesheets follows `javascript`; an explicit value wins.
    assert_equal true, Dommy::Rack::Session.resolve_load_stylesheets(nil, true)
    assert_equal false, Dommy::Rack::Session.resolve_load_stylesheets(nil, false)
    assert_equal false, Dommy::Rack::Session.resolve_load_stylesheets(false, true)
    assert_equal true, Dommy::Rack::Session.resolve_load_stylesheets(true, false)
  end

  def test_explicit_override_wins
    session = Dommy::Rack::Session.new(app, load_stylesheets: false)
    refute session.load_stylesheets?
  end

  def test_cross_origin_link_is_skipped_without_error
    app = app_for(
      "GET /page" => html_response(
        '<link rel="stylesheet" href="https://cdn.example.com/x.css"><p id="x" class="hidden">x</p>'
      )
    )
    session = Dommy::Rack::Session.new(app, load_stylesheets: true)
    session.visit("/page")
    # cross-origin CSS can't be fetched, so the class never applies
    assert Dommy::Rack.visible?(session.at_css("#x"))
  end

  def test_non_stylesheet_link_is_not_fetched
    fetched = []
    app = app_for(
      "GET /page" => html_response('<link rel="icon" href="/favicon.ico"><p id="x">x</p>'),
      "GET /favicon.ico" => ->(_req) { fetched << :favicon; [200, {"Content-Type" => "image/x-icon"}, [""]] }
    )
    session = Dommy::Rack::Session.new(app, load_stylesheets: true)
    session.visit("/page")
    assert_empty fetched
  end
end
