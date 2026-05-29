# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "dommy/rack"

require "minitest/autorun"

# Shared helpers for building small Rack apps in tests.
module RackTestHelper
  # A Rack triple serving an HTML body.
  def html_response(html, status: 200, extra_headers: {})
    [status, {"Content-Type" => "text/html"}.merge(extra_headers), [html]]
  end

  # Build an app from a routing table keyed by "METHOD /path". Values are
  # either a Rack triple or a callable taking the Rack::Request.
  def app_for(routes)
    lambda do |env|
      req = ::Rack::Request.new(env)
      handler = routes["#{req.request_method} #{req.path}"]
      next [404, {"Content-Type" => "text/plain"}, ["Not Found"]] unless handler

      handler.respond_to?(:call) ? handler.call(req) : handler
    end
  end
end
