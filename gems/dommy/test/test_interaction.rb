# frozen_string_literal: true

require_relative "test_helper"

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
end
