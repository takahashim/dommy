# frozen_string_literal: true

require "test_helper"
require_relative "support/null_runtime"

# Dommy::Browser without a JS engine: the pure-DOM surface — parsing, finding,
# interaction events, matchers — plus the strict-mode error accounting, driven
# through a no-op NullRuntime. The JS-execution behaviors (script boot order,
# currentScript, timers, real uncaught errors) are covered against the QuickJS
# backend in dommy-js-quickjs's test/dommy/js/test_browser.rb.
class TestBrowser < Minitest::Test
  PAGE = <<~HTML
    <html><body>
      <h1 id="head">Welcome</h1>
      <form>
        <label for="name">Name</label>
        <input id="name" name="name" type="text" value="initial">
        <input id="agree" type="checkbox">
        <input id="opt-a" type="radio" name="opt">
        <input id="opt-b" type="radio" name="opt">
        <select id="color">
          <option value="red">Red</option>
          <option value="green" selected>Green</option>
        </select>
        <button type="submit">Save</button>
      </form>
      <a href="/next">Continue</a>
    </body></html>
  HTML

  def browser(html = PAGE, **opts)
    Dommy::Browser.new(html, backend: :null, **opts)
  end

  def teardown
    @browser&.dispose
  end

  def open(html = PAGE, **opts)
    @browser = browser(html, **opts)
  end

  # --- construction / accessors ---

  def test_builds_window_and_document_without_a_js_engine
    b = open
    assert_kind_of Dommy::Window, b.window
    assert_equal b.window.document, b.document
    assert_includes b.html, "Welcome"
  end

  def test_boot_records_lifecycle_without_running_scripts
    b = open("<html><body><script>throw new Error('never run')</script></body></html>")
    runtime = b.runtime
    assert_equal %w[loading interactive complete], runtime.ready_states
    # The inline script body was handed to the runtime but not executed.
    assert_equal 1, runtime.loaded_scripts.length
  end

  def test_execute_scripts_false_skips_boot
    b = open("<html><body><script>1</script></body></html>", execute_scripts: false)
    assert_empty b.runtime.ready_states
    assert_empty b.runtime.loaded_scripts
  end

  # --- finding ---

  def test_find_and_all
    b = open
    assert_equal "head", b.find("h1").id
    assert_equal 2, b.all("input[type=radio]").length
  end

  def test_find_raises_when_absent
    b = open
    assert_raises(Dommy::Interaction::ElementNotFoundError) { b.find("h2") }
  end

  def test_find_filters_by_text
    b = open
    assert_equal "head", b.find("h1", text: "Welcome").id
    assert_raises(Dommy::Interaction::ElementNotFoundError) { b.find("h1", text: "Goodbye") }
  end

  # --- matchers ---

  def test_css_and_text_matchers
    b = open
    assert b.has_css?("input#name")
    assert b.has_css?("input[type=radio]", count: 2)
    refute b.has_css?("h2")
    assert b.has_text?("Welcome")
    assert b.has_text?(/Wel\w+/)
    refute b.has_text?("Missing")
  end

  def test_field_presence_matchers
    b = open
    assert b.has_field?("Name")
    assert b.has_button?("Save")
    assert b.has_link?("Continue")
    refute b.has_button?("Delete")
  end

  # --- interaction (pure DOM, no JS handlers) ---

  def test_fill_in_updates_value_and_fires_events
    b = open
    events = []
    field = b.find("#name")
    %w[focus input change].each { |type| field.add_event_listener(type) { events << type } }

    b.fill_in("Name", with: "Ada")

    assert_equal "Ada", field.value
    assert_equal %w[focus input change], events
  end

  def test_check_and_uncheck_toggle_checked_state
    b = open
    box = b.find("#agree")
    refute box.checked

    b.check("agree")
    assert box.checked

    b.uncheck("agree")
    refute box.checked
  end

  def test_choose_selects_one_radio_in_the_group
    b = open
    b.choose("opt-a")
    assert b.find("#opt-a").checked
    refute b.find("#opt-b").checked

    b.choose("opt-b")
    refute b.find("#opt-a").checked
    assert b.find("#opt-b").checked
  end

  def test_select_changes_the_selected_option
    b = open
    select_el = b.find("#color")
    b.select("Red", from: "color")

    assert_equal "red", select_el.value
  end

  def test_click_fires_dom_click_handlers
    b = open
    clicked = false
    b.find("a").add_event_listener("click") { clicked = true }

    b.click("a")

    assert clicked
  end

  def test_click_button_dispatches_submit_on_owning_form
    b = open
    submitted = false
    b.find("form").add_event_listener("submit") { submitted = true }

    b.click_button("Save")

    assert submitted
  end

  # --- strict-mode error accounting (driven via the runtime's channels) ---

  def test_strict_mode_raises_at_next_checkpoint
    b = open
    b.runtime.emit_unhandled_rejection(RuntimeError.new("boom"))
    err = assert_raises(Dommy::Browser::JsError) { b.settle }
    assert_includes err.message, "boom"
  end

  def test_allow_js_errors_suppresses_strict_failure
    b = open
    b.allow_js_errors do
      b.runtime.emit_unhandled_rejection(RuntimeError.new("expected"))
      b.settle
    end
    assert(b.js_errors.any? { |e| e.message.include?("expected") })
  end

  def test_non_strict_collects_without_raising
    b = open(strict: false)
    b.runtime.emit_unhandled_rejection(RuntimeError.new("ignored"))
    b.settle # does not raise
    assert(b.js_errors.any? { |e| e.message.include?("ignored") })
  end

  def test_dispose_raises_on_unacknowledged_errors_in_strict_mode
    b = browser
    b.runtime.emit_unhandled_rejection(RuntimeError.new("at dispose"))
    err = assert_raises(Dommy::Browser::JsError) { b.dispose }
    assert_includes err.message, "at dispose"
    @browser = nil # already disposed
  end

  def test_console_output_is_collected
    b = open
    entry = Object.new
    b.runtime.emit_log(entry)
    assert_includes b.console, entry
  end
end
