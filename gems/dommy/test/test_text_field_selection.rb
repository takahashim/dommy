# frozen_string_literal: true

require_relative "test_helper"

# HTML "APIs for the text control selections" and the textarea's values.
class TestTextFieldSelection < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<input id=i value=foo><textarea id=t>foo</textarea>")
    @doc = @win.document
    @input = @doc.get_element_by_id("i")
    @textarea = @doc.get_element_by_id("t")
  end

  def test_selection_starts_at_zero_and_value_setter_moves_it_to_the_end_only_on_change
    [@input, @textarea].each do |el|
      assert_equal [0, 0], [el.selection_start, el.selection_end]
      el.value = "foo"
      assert_equal [0, 0], [el.selection_start, el.selection_end]
      el.value = "foobar"
      assert_equal [6, 6, "none"], [el.selection_start, el.selection_end, el.selection_direction]
    end
  end

  def test_setters_follow_set_the_selection_range
    @input.value = "0123456789"
    @input.set_selection_range(2, 5)
    @input.selection_start = 8
    assert_equal [8, 8], [@input.selection_start, @input.selection_end]
    @input.selection_end = 3
    assert_equal [3, 3], [@input.selection_start, @input.selection_end]
    @input.selection_start = -1
    assert_equal 10, @input.selection_start
  end

  def test_set_range_text_edits_the_value_and_places_the_selection
    @input.value = "something"
    @input.set_selection_range(4, 9)
    @input.set_range_text("thing")
    assert_equal "something", @input.value
    @input.set_range_text("X", 0, 4, "select", explicit_range: true)
    assert_equal ["Xthing", 0, 1], [@input.value, @input.selection_start, @input.selection_end]
    assert_raises(Dommy::DOMException::IndexSizeError) { @input.set_range_text("a", 3, 1, nil, explicit_range: true) }
    # The dirty value flag is set, so the attribute no longer drives the value.
    @input.set_attribute("value", "other")
    assert_equal "Xthing", @input.value
  end

  def test_selection_offsets_are_utf16_code_units
    @input.value = "a\u{1F600}b"
    assert_equal 4, @input.selection_end
    @input.set_range_text("", 1, 3, "end", explicit_range: true)
    assert_equal "ab", @input.value
  end

  def test_a_changed_selection_queues_a_bubbling_select_event
    events = []
    @doc.add_event_listener("select", proc { |e| events << e.__js_get__("target") })
    @input.set_selection_range(0, 2)
    assert_empty events
    @win.scheduler.advance_time(0)
    assert_equal [@input], events
    @input.set_selection_range(0, 2)
    @win.scheduler.advance_time(0)
    assert_equal 1, events.length
  end

  def test_textarea_values
    @textarea.text_content = "a\r\nb\rc"
    assert_equal "a\nb\nc", @textarea.value
    assert_equal "a\r\nb\rc", @textarea.default_value
    @textarea.append_child(@doc.create_element("b")).text_content = "nested"
    assert_equal "a\r\nb\rc", @textarea.default_value
    @textarea.value = "\u{1F600}"
    assert_equal 2, @textarea.text_length
  end

  def test_textarea_hard_wrap_in_submission
    form = @doc.create_element("form")
    form.inner_html = "<textarea name=w wrap=hard cols=10>ABCDEFGHIJKLMNOPQRSTUVWXYZ\nshort</textarea>"
    @doc.body.append_child(form)
    assert_equal "ABCDEFGHIJ\nKLMNOPQRST\nUVWXYZ\nshort", Dommy::FormData.new(form).get("w")
  end

  def test_rows_and_cols_are_positive_with_fallback
    assert_equal [2, 20], [@textarea.rows, @textarea.cols]
    @textarea.set_attribute("cols", "0")
    assert_equal 20, @textarea.cols
    @textarea.cols = 0
    assert_equal "20", @textarea.get_attribute("cols")
  end
end
