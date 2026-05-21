# frozen_string_literal: true

require_relative "test_helper"
require "dommy/test_helpers"

# Verifies Dommy::TestHelpers behaves correctly when included into a
# Minitest::Test subclass — mirrors how an end-user test suite would
# pull it in via `include Dommy::TestHelpers`.
class TestTestHelpers < Minitest::Test
  include Dommy::TestHelpers

  def test_parse_html_returns_document_with_body_content
    dom = parse_html("<div id='x'>Hello</div>")
    assert_kind_of(Dommy::Document, dom)
    assert_equal("Hello", dom.query_selector("#x").text_content)
  end

  def test_parse_html_with_empty_string_returns_empty_document
    dom = parse_html
    assert_kind_of(Dommy::Document, dom)
    assert_equal("", dom.body.inner_html)
  end

  def test_parse_html_returns_fresh_document_each_call
    dom1 = parse_html("<p id='a'>A</p>")
    dom2 = parse_html("<p id='b'>B</p>")
    refute_equal(dom1, dom2)
    assert_nil(dom1.query_selector("#b"))
    assert_nil(dom2.query_selector("#a"))
  end

  def test_parse_html_handles_full_document_with_doctype
    dom = parse_html(
      <<~HTML
        <!doctype html>
        <html>
          <head><title>Hello</title></head>
          <body><h1 id="t">Heading</h1></body>
        </html>
      HTML
    )
    assert_equal("Heading", dom.query_selector("#t").text_content)
    assert_equal("Hello", dom.title)
  end

  def test_parse_html_handles_full_document_with_html_tag
    dom = parse_html("<html><head><title>X</title></head><body><p id='p'>Y</p></body></html>")
    assert_equal("Y", dom.query_selector("#p").text_content)
    assert_equal("X", dom.title)
  end

  def test_parse_html_treats_fragment_as_body_content
    dom = parse_html("<div id='d'>Frag</div>")
    assert_equal("Frag", dom.query_selector("#d").text_content)
    # no <title> in fragment
    assert_equal("", dom.title)
  end

  def test_make_window_returns_window
    win = make_window("<div></div>")
    assert_kind_of(Dommy::Window, win)
    assert_equal(1, win.document.query_selector_all("div").length)
  end

  def test_make_window_yields_window_to_block
    yielded = nil
    win = make_window("<span></span>") { |w| yielded = w }
    assert_same(win, yielded)
  end

  def test_flush_microtasks_fires_mutation_observer_callbacks
    win = make_window("<ul id='list'></ul>")
    records = []
    obs = Dommy::MutationObserver.new(win, proc { |recs| records.concat(recs) })
    list = win.document.query_selector("#list")
    obs.__js_call__("observe", [list, {"childList" => true}])

    list.append_child(win.document.create_element("li"))
    assert_empty(records, "MutationObserver should not fire synchronously")

    flush_microtasks(win)
    refute_empty(records, "MutationObserver should fire after flushing microtasks")
  end

  def test_advance_time_runs_scheduled_timers
    win = make_window
    fired = false
    win.scheduler.set_timeout(proc { fired = true }, 50)

    refute(fired, "Timer should not fire before time advances")
    advance_time(win, 50)
    assert(fired, "Timer should fire after advancing past its delay")
  end
end
