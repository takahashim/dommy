# frozen_string_literal: true

require "test_helper"

# HTML §4.8.5 / §7.3.1: an iframe connected to a document that has a browsing
# context gets a child navigable at once — its first document the initial
# about:blank — and is navigated to its `src` / `srcdoc` from a task; removing
# it destroys the navigable.
class TestChildNavigables < Minitest::Test
  include DommyTestHelper

  # A navigation delegate for the parent window that serves frame loads from a
  # map, recording each request.
  class FrameServer < Dommy::Navigation::NullDelegate
    attr_reader :frame_loads

    def initialize(pages)
      super()
      @pages = pages
      @frame_loads = []
    end

    def load_frame(_frame, url:, **)
      @frame_loads << url
      body = @pages[url]
      return Dommy::Internal::ChildNavigable.error_window(url) unless body

      Dommy::Internal::ChildNavigable.window_for_response(body, "text/html", url)
    end
  end

  def setup
    @win = make_window("<p>top</p>")
    @win.location.__internal_set_url__("https://a.test/dir/page.html")
    @doc = @win.document
  end

  def run_tasks
    @win.scheduler.advance_time(0)
  end

  def frame(attrs = {})
    f = @doc.create_element("iframe")
    attrs.each { |k, v| f.set_attribute(k.to_s, v) }
    f
  end

  def test_a_disconnected_iframe_has_no_navigable
    f = frame
    assert_nil f.content_document
    assert_nil f.content_window
  end

  def test_an_iframe_in_a_document_without_a_browsing_context_has_no_navigable
    other = @doc.implementation.create_html_document("x")
    f = other.create_element("iframe")
    other.body.append_child(f)
    assert_nil f.content_document
  end

  def test_inserting_a_srcless_iframe_fires_load_during_the_insertion
    f = frame
    events = []
    f.add_event_listener("load", ->(e) { events << %w[isTrusted bubbles cancelable].map { |k| e.__js_get__(k) } })
    @doc.body.append_child(f)

    assert_equal [[true, false, false]], events
    assert_equal "about:blank", f.content_document.url
    assert_equal "https://a.test", f.content_window.origin, "the initial about:blank inherits its creator's origin"
  end

  def test_about_blank_with_a_fragment_is_the_initial_document_with_that_url
    f = frame(src: "about:blank#foo")
    loads = 0
    f.add_event_listener("load", ->(_e) { loads += 1 })
    @doc.body.append_child(f)

    assert_equal 1, loads
    assert_equal "about:blank#foo", f.content_document.url
  end

  def test_an_iframe_with_a_src_has_the_initial_about_blank_until_its_navigation_task
    @win.navigation_delegate = FrameServer.new("https://a.test/dir/f.html" => "<p id='x'>framed</p>")
    f = frame(src: "f.html")
    loads = 0
    f.add_event_listener("load", ->(_e) { loads += 1 })
    @doc.body.append_child(f)

    assert_equal "about:blank", f.content_document.url
    assert_equal 0, loads, "no load during the insertion"

    run_tasks

    assert_equal 1, loads
    assert_equal "https://a.test/dir/f.html", f.content_document.url
    assert_equal "framed", f.content_document.get_element_by_id("x").text_content
    assert_equal ["https://a.test/dir/f.html"], @win.navigation_delegate.frame_loads
  end

  # A navigation from the initial about:blank to a same-origin document keeps
  # the Window (HTML "create and initialize a Document object").
  def test_a_same_origin_load_reuses_the_initial_about_blank_window
    @win.navigation_delegate = FrameServer.new("https://a.test/dir/f.html" => "<p>framed</p>")
    f = frame(src: "f.html")
    @doc.body.append_child(f)
    initial = f.content_window

    run_tasks

    assert_same initial, f.content_window
    assert_equal "https://a.test/dir/f.html", initial.location.href
    refute initial.closed?
  end

  def test_a_failed_load_shows_an_opaque_error_document_and_fires_load
    @win.navigation_delegate = FrameServer.new({})
    f = frame(src: "missing.html")
    loads = 0
    f.add_event_listener("load", ->(_e) { loads += 1 })
    @doc.body.append_child(f)
    run_tasks

    assert_equal 1, loads
    assert_equal "null", f.content_window.origin
    assert_nil f.__js_get__("contentDocument"), "a cross-origin document is not exposed to script"
    refute_nil f.content_document, "the Ruby accessor still reaches it"
  end

  def test_without_a_delegate_that_loads_frames_the_initial_document_stays
    f = frame(src: "f.html")
    @doc.body.append_child(f)
    run_tasks

    assert_equal "about:blank", f.content_document.url
  end

  def test_srcdoc_is_navigated_from_a_task
    f = frame(srcdoc: "<p id='s'>hi</p>")
    loads = 0
    f.add_event_listener("load", ->(_e) { loads += 1 })
    @doc.body.append_child(f)
    assert_equal "about:blank", f.content_document.url
    assert_equal 0, loads

    run_tasks

    assert_equal 1, loads
    assert_equal "about:srcdoc", f.content_document.url
    assert_equal "hi", f.content_document.get_element_by_id("s").text_content
    assert_equal "https://a.test/dir/page.html", f.content_document.base_uri
  end

  def test_data_and_blob_urls_are_loaded_without_a_delegate
    f = frame(src: "data:text/html,<p id=d>data</p>")
    @doc.body.append_child(f)
    run_tasks
    assert_equal "data", f.content_document.get_element_by_id("d").text_content
    assert_equal "null", f.content_window.origin

    blob = Dommy::Blob.new(["<p id=b>blob</p>"], {"type" => "text/html"})
    url = Dommy::URL.create_object_url(blob, origin: "https://a.test")
    g = frame(src: url)
    @doc.body.append_child(g)
    run_tasks
    assert_equal "blob", g.content_document.get_element_by_id("b").text_content
  end

  def test_a_text_response_becomes_a_quirks_mode_html_document_holding_a_pre
    f = frame(src: "data:text/plain,<p>not markup</p>")
    @doc.body.append_child(f)
    run_tasks
    doc = f.content_document

    assert_equal "<html><head></head><body><pre>&lt;p&gt;not markup&lt;/p&gt;</pre></body></html>",
                 doc.document_element.outer_html
    assert_equal "text/plain", doc.content_type
    assert_equal "BackCompat", doc.compat_mode
    assert doc.html_document?
    assert_equal "DIV", doc.create_element("div").tag_name
  end

  def test_changing_src_navigates_and_removing_it_goes_to_about_blank
    f = frame(src: "data:text/html,<p>one</p>")
    @doc.body.append_child(f)
    run_tasks
    loads = 0
    f.add_event_listener("load", ->(_e) { loads += 1 })

    f.remove_attribute("src")
    assert_includes f.content_document.body.text_content, "one", "not synchronously"
    run_tasks

    assert_equal 1, loads
    assert_equal "about:blank", f.content_document.url
    assert_equal "", f.content_document.body.text_content
  end

  def test_only_the_latest_navigation_completes
    f = frame
    @doc.body.append_child(f)
    loads = 0
    f.add_event_listener("load", ->(_e) { loads += 1 })
    f.set_attribute("src", "data:text/html,first")
    f.set_attribute("src", "data:text/html,second")
    run_tasks

    assert_equal 1, loads
    assert_equal "second", f.content_document.body.text_content
  end

  def test_src_set_while_srcdoc_is_present_is_ignored
    f = frame(srcdoc: "<p>s</p>")
    @doc.body.append_child(f)
    run_tasks
    f.set_attribute("src", "data:text/html,other")
    run_tasks

    assert_equal "about:srcdoc", f.content_document.url
  end

  def test_a_src_an_ancestor_already_shows_is_not_loaded
    @win.navigation_delegate = FrameServer.new({})
    f = frame(src: "page.html#x")
    @doc.body.append_child(f)
    run_tasks

    assert_equal "about:blank", f.content_document.url
    assert_empty @win.navigation_delegate.frame_loads
  end

  def test_removing_the_iframe_destroys_its_navigable
    f = frame
    @doc.body.append_child(f)
    inner = f.content_window

    f.remove

    assert_nil f.content_window
    assert_nil f.content_document
    assert inner.closed?
    assert_nil inner.parent_window

    @doc.body.append_child(f)
    refute_nil f.content_window
    refute_same inner, f.content_window, "a new navigable on reinsertion"
  end

  def test_removal_drops_a_navigation_in_flight
    f = frame(src: "data:text/html,late")
    @doc.body.append_child(f)
    f.remove
    run_tasks

    assert_nil f.content_document
  end

  def test_a_navigation_from_inside_the_frame_navigates_its_navigable
    f = frame
    @doc.body.append_child(f)
    loads = 0
    f.add_event_listener("load", ->(_e) { loads += 1 })

    f.content_window.location.__js_set__("href", "data:text/html,inside")
    run_tasks

    assert_equal 1, loads
    assert_equal "inside", f.content_document.body.text_content
  end

  def test_a_link_targeting_the_frame_by_name_navigates_it
    f = frame(name: "kid")
    @doc.body.append_child(f)
    a = @doc.create_element("a")
    a.set_attribute("href", "data:text/html,linked")
    a.set_attribute("target", "kid")
    @doc.body.append_child(a)

    a.click
    run_tasks

    assert_equal "linked", f.content_document.body.text_content
    assert_equal "https://a.test/dir/page.html", @win.location.href
  end

  def test_the_navigable_keeps_its_name_across_navigations
    f = frame(name: "kid", src: "data:text/html,x")
    @doc.body.append_child(f)
    f.content_window.__js_set__("name", "renamed")
    run_tasks

    assert_equal "renamed", f.content_window.name
  end

  def test_a_lazy_frame_waits_for_its_document_to_load
    @win.navigation_delegate = FrameServer.new("https://a.test/dir/f.html" => "<p>lazy</p>")
    @doc.__internal_set_ready_state__("loading")
    f = frame(src: "f.html", loading: "lazy")
    @doc.body.append_child(f)
    run_tasks
    assert_equal "about:blank", f.content_document.url
    refute @doc.__internal_load_delayed__?, "a lazy frame does not delay the load event"

    @doc.__internal_set_ready_state__("interactive")
    @doc.__internal_set_ready_state__("complete")
    run_tasks

    assert_equal "https://a.test/dir/f.html", f.content_document.url
  end

  def test_making_a_lazy_frame_eager_resumes_its_load
    @doc.__internal_set_ready_state__("loading")
    f = frame(src: "data:text/html,eager", loading: "lazy")
    @doc.body.append_child(f)
    f.set_attribute("loading", "eager")
    run_tasks

    assert_equal "eager", f.content_document.body.text_content
  end

  def test_a_pending_navigation_delays_the_load_event
    f = frame(src: "data:text/html,x")
    @doc.body.append_child(f)
    assert @doc.__internal_load_delayed__?
    run_tasks
    refute @doc.__internal_load_delayed__?
  end

  def test_parsed_iframes_are_processed_when_script_boot_replays_the_parse
    win = Dommy.parse("<!doctype html><html><body><iframe id='f' srcdoc='<p>p</p>'></iframe></body></html>")
    f = win.document.get_element_by_id("f")
    win.document.__internal_process_parsed_iframes__
    win.scheduler.advance_time(0)

    assert_equal "about:srcdoc", f.content_document.url
  end
end
