# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "dommy"

# Run the whole suite against a chosen parser backend, e.g.
#   DOMMY_BACKEND=makiri bundle exec rake test
Dommy::Backend.use(ENV["DOMMY_BACKEND"].to_sym) if ENV["DOMMY_BACKEND"]

module DommyTestHelper
  # Spin up a fresh `<html><head></head><body>BODY</body></html>` and
  # return the wrapped Window. Mirrors `Dommy.parse` but lets the
  # caller customize body inline.
  def make_window(body_html = "")
    win = Dommy::Window.new
    win.document.body.inner_html = body_html
    win
  end
end
