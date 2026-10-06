# frozen_string_literal: true

require "test_helper"
require_relative "support/null_runtime"

# HTML §13.2.7 "The end": once the parser stops, the document becomes
# "interactive", deferred scripts run, and DOMContentLoaded and then `load`
# fire from tasks of their own — so work a script queued before them (a timer,
# a history traversal, a frame's navigation) runs first. Script boot runs
# those tasks before it returns, so a booted page is loaded.
class TestTheEnd < Minitest::Test
  # A runtime that applies the lifecycle to the document (as a real engine's
  # port does) and "runs" a script by calling the Ruby block registered under
  # its source text.
  class LifecycleRuntime < DommyTestSupport::NullRuntime
    SCRIPTS = {}

    def install_window(window)
      @window = window
    end

    def set_document_ready_state(state)
      super
      @window.document.__internal_set_ready_state__(state)
    end

    def load_script(js)
      super
      SCRIPTS[js.strip]&.call(@window)
    end
  end

  Dommy::Js.register_runtime(:lifecycle) { LifecycleRuntime.new } unless Dommy::Js.runtime_registered?(:lifecycle)

  def setup
    @log = []
  end

  def teardown
    LifecycleRuntime::SCRIPTS.clear
    @browser&.dispose
  end

  def script(name, &block)
    LifecycleRuntime::SCRIPTS[name] = block
    "<script>#{name}</script>"
  end

  def boot(body)
    @browser = Dommy::Browser.new("<!doctype html><html><body>#{body}</body></html>", backend: :lifecycle)
  end

  def listen(window)
    doc = window.document
    doc.add_event_listener("readystatechange", ->(_e) { @log << "readystatechange:#{doc.__js_get__('readyState')}" })
    doc.add_event_listener("DOMContentLoaded", ->(_e) { @log << "DOMContentLoaded" })
    window.add_event_listener("load", ->(_e) { @log << "load" })
    window.add_event_listener("pageshow", ->(_e) { @log << "pageshow" })
  end

  def test_milestones_fire_from_tasks_after_work_queued_before_them
    b = boot(script("setup") do |w|
      listen(w)
      w.scheduler.set_timeout(proc { @log << "timer" }, 0)
      @log << "script"
    end)

    assert_equal %w[script readystatechange:interactive timer DOMContentLoaded readystatechange:complete load pageshow], @log
    assert_equal "complete", b.document.__js_get__("readyState")
    assert b.document.__internal_completely_loaded__?
  end

  def test_a_later_timer_stays_pending_after_boot
    boot(script("later") do |w|
      listen(w)
      w.scheduler.set_timeout(proc { @log << "later" }, 50)
    end)

    refute_includes @log, "later"
    assert_includes @log, "load"
  end

  def test_a_history_traversal_queued_during_parsing_runs_before_load
    boot(script("traverse") do |w|
      listen(w)
      w.add_event_listener("popstate", ->(_e) { @log << "popstate" })
      w.history.__js_call__("pushState", ["s1", ""])
      w.history.__js_call__("pushState", ["s2", ""])
      w.history.__js_call__("go", [-1])
    end)

    assert_operator @log.index("popstate"), :<, @log.index("load")
  end

  def test_a_frame_navigation_completes_before_load
    page = "<iframe id='f' srcdoc='<p>inner</p>'></iframe>" + script("frame") do |w|
      listen(w)
      w.document.get_element_by_id("f").add_event_listener("load", ->(_e) { @log << "iframe-load" })
    end
    boot(page)

    assert_operator @log.index("iframe-load"), :<, @log.index("load")
  end
end
