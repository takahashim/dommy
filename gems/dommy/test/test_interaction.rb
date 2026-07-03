# frozen_string_literal: true

require_relative "test_helper"
require_relative "support/null_runtime"

# The shared interaction layer (Dommy::Interaction): event synthesis, field
# interaction with input/change events, form serialization, and the locator.
class TestInteraction < Minitest::Test
  include DommyTestHelper

  def test_event_synthesis_click_dispatches_full_sequence
    win = make_window("<button id='b'>x</button>")
    button = win.document.get_element_by_id("b")
    seen = []
    %w[pointerdown mousedown focus pointerup mouseup click].each do |type|
      button.add_event_listener(type, ->(e) { seen << e.type })
    end

    prevented = Dommy::Interaction::EventSynthesis.click(button)
    assert_equal %w[pointerdown mousedown focus pointerup mouseup click], seen
    assert_equal false, prevented
  end

  def test_event_synthesis_click_reports_prevent_default
    win = make_window("<a id='a' href='#'>x</a>")
    link = win.document.get_element_by_id("a")
    link.add_event_listener("click", ->(e) { e.__js_call__("preventDefault", []) })

    assert_equal true, Dommy::Interaction::EventSynthesis.click(link)
  end

  def test_field_interactor_fill_in_fires_input_and_change
    win = make_window("<input id='f'>")
    doc = win.document
    field = doc.get_element_by_id("f")
    events = []
    field.add_event_listener("input", ->(_e) { events << "input:#{field.value}" })
    field.add_event_listener("change", ->(_e) { events << "change:#{field.value}" })

    fi = Dommy::Interaction::FieldInteractor.new(Dommy::Interaction::Locator.new(doc), doc)
    fi.fill_in("f", with: "hello")

    assert_equal "hello", field.value
    assert_equal ["input:hello", "change:hello"], events
  end

  def test_field_interactor_check_fires_change
    win = make_window("<input type='checkbox' id='c'>")
    doc = win.document
    box = doc.get_element_by_id("c")
    fired = false
    box.add_event_listener("change", ->(_e) { fired = true })

    Dommy::Interaction::FieldInteractor.new(Dommy::Interaction::Locator.new(doc), doc).check("c")

    assert box.checked
    assert fired
  end

  def test_form_submission_takes_method_override_keywords
    win = make_window(<<~HTML)
      <form method="post" action="/p">
        <input name="_method" value="patch">
        <input name="title" value="hi">
        <button type="submit">Go</button>
      </form>
    HTML
    form = win.document.query_selector("form")
    submitter = win.document.query_selector("button")

    result = Dommy::Interaction::FormSubmission.new(
      form, submitter, respect_method_override: true, method_override_param: "_method"
    ).submit!

    assert_equal "PATCH", result[:method]
    assert_includes result[:params], ["title", "hi"]
    refute(result[:params].any? { |name, _| name == "_method" }, "override param is consumed")
  end

  def test_has_css_with_text_and_count
    win = make_window(<<~HTML)
      <ul><li class="todo">Buy milk</li><li class="todo">Walk dog</li></ul>
    HTML
    driver = Object.new.extend(Dommy::Interaction::Driver)
    driver.define_singleton_method(:document) { win.document }

    assert driver.has_css?("li.todo")
    assert driver.has_css?("li.todo", text: "Buy milk")
    assert driver.has_css?("li.todo", text: /walk/i)
    refute driver.has_css?("li.todo", text: "Cook dinner")
    assert driver.has_css?("li.todo", count: 2)
    refute driver.has_css?("li.todo", count: 1)
    assert driver.has_css?("li.todo", text: "Buy milk", count: 1)
    assert driver.has_no_css?("li.todo", text: "nope")
  end

  def test_find_and_all_with_text_filter
    win = make_window(<<~HTML)
      <ul><li class="todo">Buy milk</li><li class="todo">Walk dog</li></ul>
    HTML
    driver = Object.new.extend(Dommy::Interaction::Driver)
    driver.define_singleton_method(:document) { win.document }

    assert_equal 2, driver.all("li.todo").size
    assert_equal 1, driver.all("li.todo", text: "Walk").size
    assert_equal 0, driver.all("li.todo", text: "Cook").size

    assert_equal "Buy milk", driver.find("li.todo", text: "Buy milk").text_content
    assert_equal "Walk dog", driver.find("li.todo", text: /walk/i).text_content
    assert_raises(Dommy::Interaction::ElementNotFoundError) { driver.find("li.todo", text: "Cook") }
  end

  def test_has_text_accepts_regexp
    win = make_window("<p>Status: Done</p>")
    driver = Object.new.extend(Dommy::Interaction::Driver)
    driver.define_singleton_method(:document) { win.document }

    assert driver.has_text?("Done")
    assert driver.has_text?(/done/i)
    refute driver.has_text?(/active/i)
    assert driver.has_no_text?(/active/i)
  end

  def test_scheduler_next_animation_frame_at
    sched = Dommy::Scheduler.new
    assert_nil sched.next_animation_frame_at

    sched.request_animation_frame(-> {})
    assert_equal 16, sched.next_animation_frame_at
    # A plain timer does not count as an animation frame.
    sched.set_timeout(-> {}, 500)
    assert_equal 16, sched.next_animation_frame_at
  end

  # --- Driver#send_keys ---

  def sendkeys_browser(html)
    Dommy::Browser.new(html, backend: :null)
  end

  def test_send_keys_named_key_dispatches_keydown_and_keyup
    b = sendkeys_browser("<input id='q'>")
    seen = []
    field = b.find("#q")
    %w[keydown keyup].each do |type|
      field.add_event_listener(type, ->(e) { seen << [e.type, e.__js_get__("key"), e.__js_get__("code")] })
    end

    b.send_keys("#q", :arrow_down)

    assert_equal [["keydown", "ArrowDown", "ArrowDown"], ["keyup", "ArrowDown", "ArrowDown"]], seen
  end

  def test_send_keys_types_text_with_full_event_sequence_and_value
    b = sendkeys_browser("<input id='q'>")
    field = b.find("#q")
    seen = []
    %w[keydown keypress beforeinput input keyup].each do |type|
      field.add_event_listener(type, ->(e) { seen << e.type })
    end

    b.send_keys("#q", "ab")

    assert_equal "ab", field.value
    assert_equal %w[keydown keypress beforeinput input keyup] * 2, seen
  end

  def test_send_keys_prevented_keydown_suppresses_insertion
    b = sendkeys_browser("<input id='q'>")
    field = b.find("#q")
    field.add_event_listener("keydown", ->(e) { e.__js_call__("preventDefault", []) })
    keyups = 0
    field.add_event_listener("keyup", ->(_e) { keyups += 1 })

    b.send_keys("#q", "x")

    assert_equal "", field.value.to_s
    assert_equal 1, keyups
  end

  def test_send_keys_backspace_deletes_last_character
    b = sendkeys_browser("<input id='q' value='abc'>")
    field = b.find("#q")
    input_types = []
    field.add_event_listener("input", ->(e) { input_types << e.__js_get__("inputType") })

    b.send_keys("#q", :backspace)

    assert_equal "ab", field.value
    assert_equal ["deleteContentBackward"], input_types
  end

  def test_send_keys_enter_runs_implicit_form_submission_via_default_button
    b = sendkeys_browser(<<~HTML)
      <form id='f'><input id='q'><button type='submit' id='go'>Go</button></form>
    HTML
    seen = []
    b.find("#go").add_event_listener("click", ->(_e) { seen << "button-click" })
    b.find("#f").add_event_listener("submit", ->(e) { seen << "submit"; e.__js_call__("preventDefault", []) })

    b.send_keys("#q", :enter)

    assert_equal %w[button-click submit], seen
  end

  def test_send_keys_prevented_enter_does_not_submit
    b = sendkeys_browser(<<~HTML)
      <form id='f'><input id='q'><button type='submit'>Go</button></form>
    HTML
    submitted = false
    b.find("#f").add_event_listener("submit", ->(_e) { submitted = true })
    b.find("#q").add_event_listener("keydown", ->(e) { e.__js_call__("preventDefault", []) })

    b.send_keys("#q", :enter)

    refute submitted
  end

  def test_send_keys_enter_in_textarea_inserts_newline
    b = sendkeys_browser("<textarea id='t'>hi</textarea>")

    b.send_keys("#t", :enter)

    assert_equal "hi\n", b.find("#t").value
  end

  def test_send_keys_focuses_target_once
    b = sendkeys_browser("<input id='q'>")
    field = b.find("#q")
    focuses = 0
    field.add_event_listener("focus", ->(_e) { focuses += 1 })

    b.send_keys("#q", "a")
    b.send_keys("#q", "b")

    assert_equal field, b.window.document.active_element
    assert_equal 1, focuses
  end

  def test_send_keys_unknown_named_key_raises
    b = sendkeys_browser("<input id='q'>")

    assert_raises(ArgumentError) { b.send_keys("#q", :warp_speed) }
  end

  # --- Element#focus focusing steps / KeyboardEvent legacy surface ---

  def test_focus_fires_focus_change_events_with_related_targets
    win = make_window("<input id='a'><input id='b'>")
    doc = win.document
    a = doc.get_element_by_id("a")
    b = doc.get_element_by_id("b")
    seen = []
    [a, b].each do |el|
      %w[focus focusin blur focusout].each do |type|
        el.add_event_listener(type, ->(e) { seen << "#{el.id}:#{e.type}:#{e.__js_get__("relatedTarget")&.id}" })
      end
    end

    a.focus
    b.focus

    assert_equal ["a:focus:", "a:focusin:", "a:blur:b", "a:focusout:b", "b:focus:a", "b:focusin:a"], seen
    assert_equal b, doc.active_element
  end

  def test_focus_is_a_noop_when_already_focused_or_disabled
    win = make_window("<input id='a'><input id='d' disabled>")
    doc = win.document
    a = doc.get_element_by_id("a")
    focuses = 0
    a.add_event_listener("focus", ->(_e) { focuses += 1 })

    a.focus
    a.focus
    doc.get_element_by_id("d").focus

    assert_equal 1, focuses
    assert_equal a, doc.active_element
  end

  def test_blur_fires_blur_and_focusout_and_resets_active_element
    win = make_window("<input id='a'>")
    doc = win.document
    a = doc.get_element_by_id("a")
    seen = []
    %w[blur focusout].each { |t| a.add_event_listener(t, ->(e) { seen << e.type }) }

    a.focus
    a.blur

    assert_equal %w[blur focusout], seen
    assert_equal doc.body, doc.active_element
  end

  def test_keyboard_event_legacy_key_code_surface
    down = Dommy::KeyboardEvent.new("keydown", "key" => "a")
    press = Dommy::KeyboardEvent.new("keypress", "key" => "a")
    enter = Dommy::KeyboardEvent.new("keydown", "key" => "Enter")

    assert_equal 65, down.__js_get__("keyCode")
    assert_equal 0, down.__js_get__("charCode")
    assert_equal 65, down.__js_get__("which")
    assert_equal 97, press.__js_get__("keyCode")
    assert_equal 97, press.__js_get__("charCode")
    assert_equal 13, enter.__js_get__("keyCode")
    assert_equal 13, enter.__js_get__("which")
  end

  def test_keyboard_event_modifier_state_and_metadata
    e = Dommy::KeyboardEvent.new("keydown",
      "key" => "A", "shiftKey" => true, "repeat" => true, "location" => 1)

    assert_equal true, e.__js_call__("getModifierState", ["Shift"])
    assert_equal false, e.__js_call__("getModifierState", ["Control"])
    assert_equal false, e.__js_call__("getModifierState", ["CapsLock"])
    assert_equal true, e.__js_get__("repeat")
    assert_equal 1, e.__js_get__("location")
    assert_equal false, e.__js_get__("isComposing")
  end
end
