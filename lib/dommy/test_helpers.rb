# frozen_string_literal: true

module Dommy
  # Lightweight helpers for using Dommy from RSpec / Minitest test suites.
  #
  # @example RSpec
  #   require "dommy/test_helpers"
  #
  #   RSpec.configure do |c|
  #     c.include Dommy::TestHelpers
  #   end
  #
  #   RSpec.describe MyComponent do
  #     it "renders the heading" do
  #       dom = parse_html(render(MyComponent.new))
  #       expect(dom.query_selector("h1").text_content).to eq("Welcome")
  #     end
  #   end
  #
  # @example Minitest
  #   require "dommy/test_helpers"
  #
  #   class MyComponentTest < Minitest::Test
  #     include Dommy::TestHelpers
  #
  #     def test_renders_the_heading
  #       dom = parse_html(render(MyComponent.new))
  #       assert_equal "Welcome", dom.query_selector("h1").text_content
  #     end
  #   end
  module TestHelpers
    # Parse an HTML string into a fresh Document and return it.
    #
    # When the input starts with `<!doctype` or `<html>`, it is parsed as
    # a full HTML document (preserving <head>, <title>, etc.). Otherwise
    # the input is treated as a body fragment and inserted into a fresh
    # document's <body>.
    #
    # @param html [String] HTML to parse (full document or body fragment)
    # @return [Dommy::Document] a fresh Document with the parsed content
    def parse_html(html = "")
      Dommy.parse(html).document
    end

    # Build a fresh Window with the given body HTML.
    # When a block is given, yields the window first; the same window
    # is returned in both cases so callers can choose their style.
    #
    # @param body_html [String] HTML to insert inside <body>
    # @yieldparam window [Dommy::Window]
    # @return [Dommy::Window] the new Window
    def make_window(body_html = "")
      window = Dommy::Window.new
      window.document.body.inner_html = body_html.to_s
      yield window if block_given?
      window
    end

    # Drain pending microtasks on the window's scheduler.
    # Use this after a mutation if you need MutationObserver callbacks
    # (scheduled as microtasks) to fire before your assertions.
    #
    # @param window [Dommy::Window]
    def flush_microtasks(window)
      window.scheduler.drain_microtasks
    end

    # Advance the window's virtual clock. Timers that come due and
    # any queued microtasks are run as part of the advance.
    # Use this to test code that schedules work with setTimeout / setInterval.
    #
    # @param window [Dommy::Window]
    # @param ms [Integer] milliseconds to advance
    def advance_time(window, ms)
      window.scheduler.advance_time(ms)
    end
  end
end
