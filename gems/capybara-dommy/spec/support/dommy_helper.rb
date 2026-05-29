# frozen_string_literal: true

# Helpers for the fast unit specs. Mixed into every example group via
# RSpec.configure in spec_helper.rb.
module CapybaraDommyTestHelper
  # Build a Rack app from a routing table keyed by "METHOD /path". Values are
  # either a Rack triple or a callable taking the Rack::Request.
  def app_for(routes)
    lambda do |env|
      req = ::Rack::Request.new(env)
      handler = routes["#{req.request_method} #{req.path}"]
      next [404, {"Content-Type" => "text/plain"}, ["Not Found"]] unless handler

      handler.respond_to?(:call) ? handler.call(req) : handler
    end
  end

  def html_response(html, status: 200, extra_headers: {})
    [status, {"Content-Type" => "text/html"}.merge(extra_headers), [html]]
  end

  # A Capybara session driven by :dommy over the given app.
  def session_for(app)
    Capybara::Session.new(:dommy, app)
  end

  # A driver (not wrapped in a Capybara::Session) for unit-level node tests.
  def driver_for(html, **options)
    driver = Capybara::Dommy::Driver.new(html_app(html), **options)
    driver.visit("/")
    driver
  end

  def html_app(html)
    ->(_env) { [200, {"Content-Type" => "text/html"}, [html]] }
  end
end
