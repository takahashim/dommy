# frozen_string_literal: true

require_relative "test_helper"

# HTML "constructing the entry list" fires a `formdata` event so a listener can
# mutate the FormData before it is submitted. WPT: html/semantics/forms/
# form-submission-0/formdata-event.html.
class TestFormDataEventOnSubmit < Minitest::Test
  include DommyTestHelper

  def build(html)
    win = make_window(html)
    [win, win.document.query_selector("form")]
  end

  def submit(form)
    Dommy::Interaction::FormSubmission.new(form, nil).submit!
  end

  def test_a_listener_can_append_an_entry
    _win, form = build('<form action="/x" method="post"><input name="a" value="1"></form>')
    form.add_event_listener("formdata") { |e| e.form_data.append("extra", "z") }

    result = submit(form)

    assert_includes(result[:params], ["extra", "z"])
    assert_includes(result[:params], ["a", "1"])
  end

  def test_a_listener_can_delete_an_entry
    _win, form = build('<form action="/x" method="post"><input name="a" value="1"></form>')
    form.add_event_listener("formdata") { |e| e.form_data.delete("a") }

    assert_empty(submit(form)[:params])
  end

  def test_the_event_carries_the_collected_entries_and_bubbles
    win, form = build('<form action="/x" method="post"><input name="a" value="1"></form>')
    seen = nil
    win.document.add_event_listener("formdata") { |e| seen = e }

    submit(form)

    refute_nil(seen, "formdata bubbles to the document")
    assert_instance_of(Dommy::FormDataEvent, seen)
    assert_equal("1", seen.form_data.get("a"))
    assert(seen.__js_get__("bubbles"))
  end

  def test_the_constructor_exposes_form_data
    event = Dommy::FormDataEvent.new("formdata", "formData" => Dommy::FormData.new)
    refute_nil(event.form_data)
    assert_instance_of(Dommy::FormData, event.__js_get__("formData"))
  end
end
