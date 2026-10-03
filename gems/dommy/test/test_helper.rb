# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "dommy"

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
