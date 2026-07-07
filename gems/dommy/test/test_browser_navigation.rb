# frozen_string_literal: true

require "test_helper"
require_relative "support/null_runtime"

# Navigation N3: cross-document document replacement driven by the core Browser
# acting as its own NavigationDelegate. Fetch the target through a Resources
# adapter, fire the old document's unload, and replace the Window + JS realm,
# with the Browser handle (joint history, resources) surviving. Exercised
# through the Ruby-driven navigation paths (visit / click / form / back /
# forward) against the no-op :null runtime; the JS-initiated deferral
# (location.href= inside a script) is covered against QuickJS in
# dommy-js-quickjs's browser tests.
class TestBrowserNavigation < Minitest::Test
  def teardown
    @browser&.dispose
  end

  def html(body) = "<!doctype html><html><head></head><body>#{body}</body></html>"

  def resources(pages)
    entries = pages.transform_values do |v|
      v.is_a?(Hash) ? v : {"body" => v, "content_type" => "text/html"}
    end
    Dommy::Resources.static(entries)
  end

  def visit(pages = {}, at: "http://localhost/", backend: :null, **opts)
    # Ruby folds a string-keyed literal (the page map) into **opts; pull it back
    # out so callers can write `visit("/" => html(...))` without extra braces.
    pages = pages.merge(opts.select { |k, _| k.is_a?(String) })
    real_opts = opts.reject { |k, _| k.is_a?(String) }
    @browser = Dommy::Browser.visit(at, resources: resources(pages), backend: backend, **real_opts)
  end

  # --- initial visit + document identity ---

  def test_visit_fetches_initial_document_and_seeds_history
    b = visit("/" => html("<h1>home</h1>"))

    assert_equal "http://localhost/", b.current_url
    assert_equal "home", b.document.query_selector("h1").text_content
    assert_equal 1, b.history.length
    assert_equal ["http://localhost/"], b.history.entries
  end

  # --- link activation performs a real cross-document navigation ---

  def test_link_click_replaces_the_document
    b = visit(
      "/" => html("<a id='go' href='/next'>next</a>"),
      "/next" => html("<h1>next page</h1>")
    )
    first_window = b.window

    b.click_link("next")

    assert_equal "http://localhost/next", b.current_url
    assert_equal "next page", b.document.query_selector("h1").text_content
    refute_same first_window, b.window, "a new Window backs the new document"
    assert_equal 2, b.history.length
  end

  def test_link_navigation_fires_unload_on_the_outgoing_document
    b = visit(
      "/" => html("<a id='go' href='/next'>next</a>"),
      "/next" => html("<h1>next</h1>")
    )
    events = []
    b.window.add_event_listener("pagehide", ->(_e) { events << "pagehide" })
    b.window.add_event_listener("unload", ->(_e) { events << "unload" })

    b.click_link("next")

    assert_equal %w[pagehide unload], events
  end

  # --- location.assign / reload via the delegate ---

  def test_reload_refetches_without_growing_history
    b = visit("/" => html("<h1 id='h'>home</h1>"))
    first_window = b.window

    b.reload

    assert_equal 1, b.history.length
    refute_same first_window, b.window
    assert_equal "home", b.document.query_selector("h1").text_content
  end

  # --- redirects ---

  def test_navigation_follows_redirects
    b = visit(
      "/" => html("<a id='go' href='/old'>go</a>"),
      "/old" => {"status" => 302, "headers" => {"Location" => "/new"}},
      "/new" => html("<h1>arrived</h1>")
    )

    b.click_link("go")

    assert_equal "http://localhost/new", b.current_url
    assert_equal "arrived", b.document.query_selector("h1").text_content
  end

  # --- form submission (GET) folds params into the query and navigates ---

  def test_form_get_submission_navigates_with_query
    b = visit(
      "/" => html(
        "<form id='f' method='get' action='/search'>" \
        "<input name='q' value='hi'><button id='go' type='submit'>go</button></form>"
      ),
      "/search?q=hi" => html("<h1>results</h1>")
    )
    b.document.get_element_by_id("f").request_submit(b.document.get_element_by_id("go"))
    b.settle

    assert_equal "http://localhost/search?q=hi", b.current_url
    assert_equal "results", b.document.query_selector("h1").text_content
  end

  # --- clicking a submit button follows the submission (centralized) ---

  def test_click_submit_button_navigates
    b = visit(
      "/" => html(
        "<form id='f' method='get' action='/search'>" \
        "<input name='q' value='hi'><button id='go' type='submit'>go</button></form>"
      ),
      "/search?q=hi" => html("<h1>results</h1>")
    )

    b.click_button("go")

    assert_equal "http://localhost/search?q=hi", b.current_url
    assert_equal "results", b.document.query_selector("h1").text_content
  end

  def test_click_submit_button_fires_submitevent_with_submitter
    b = visit("/" => html("<form id='f'><button id='go' type='submit'>go</button></form>"))
    go = b.document.get_element_by_id("go")
    seen = []
    b.document.get_element_by_id("f").add_event_listener("submit", lambda do |e|
      seen << e.__js_get__("submitter")
      e.__js_call__("preventDefault", []) # stay on the page so `go` stays valid
    end)

    b.click_button("go")

    assert_equal 1, seen.size
    assert_equal go, seen.first
    assert_equal "http://localhost/", b.current_url, "prevented submit does not navigate"
  end

  # --- non-document responses leave the page in place ---

  def test_non_document_response_does_not_replace_the_page
    b = visit(
      "/" => html("<a id='go' href='/data.json'>data</a>"),
      "/data.json" => {"body" => "{}", "content_type" => "application/json"}
    )
    first_window = b.window

    b.click_link("data")

    assert_same first_window, b.window, "a JSON response does not swap the document"
    assert_equal "http://localhost/", b.current_url
  end

  def test_network_miss_leaves_the_page_in_place
    b = visit("/" => html("<a id='go' href='/missing'>x</a>"))
    first_window = b.window

    b.click_link("go")

    assert_same first_window, b.window
    assert_equal "http://localhost/", b.current_url
  end

  # --- joint history back / forward re-fetch across document boundaries ---

  def test_back_and_forward_refetch_across_documents
    b = visit(
      "/" => html("<a id='go' href='/next'><span>next</span></a>"),
      "/next" => html("<h1>next</h1>")
    )
    b.click_link("next")
    assert_equal "http://localhost/next", b.current_url

    b.back
    assert_equal "http://localhost/", b.current_url
    assert(b.document.query_selector("a#go"), "the home document is restored (re-fetched)")

    b.forward
    assert_equal "http://localhost/next", b.current_url
    assert_equal "next", b.document.query_selector("h1").text_content
  end

  # --- navigation is a task: the delegate defers the swap until a drain point ---

  def test_navigation_is_deferred_until_settle
    b = visit(
      "/" => html("<h1>home</h1>"),
      "/next" => html("<h1>next</h1>")
    )
    # Simulate a JS-initiated cross-document intent reaching the delegate.
    b.window.__internal_navigate__(url: "http://localhost/next", source: :location, method: "GET")

    assert_equal "http://localhost/", b.current_url, "not swapped synchronously"

    b.settle

    assert_equal "http://localhost/next", b.current_url
    assert_equal 2, b.history.length
  end

  # --- a plain (non-navigable) browser keeps the NullDelegate ---

  def test_plain_browser_is_not_navigable
    @browser = Dommy::Browser.new(html("<a href='/x'>x</a>"), backend: :null)

    assert_nil @browser.history
    assert_instance_of Dommy::Navigation::NullDelegate, @browser.window.navigation_delegate
    assert_raises(RuntimeError) { @browser.visit("/x") }
  end
end
