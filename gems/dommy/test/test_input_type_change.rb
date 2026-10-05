# frozen_string_literal: true

require_relative "test_helper"

# HTML's "the type attribute changes state" algorithm: the value is
# re-sanitized under the new state, a File Upload on either side clears it, and
# the selection resets when a non-selectable control becomes selectable.
class TestInputTypeChange < Minitest::Test
  include DommyTestHelper

  INITIAL = "  foo\rbar  "

  def setup
    @doc = make_window.document
    @input = @doc.create_element("input")
  end

  def test_text_to_hidden_keeps_the_sanitized_value
    @input.type = "text"
    @input.value = INITIAL
    assert_equal "  foobar  ", @input.value

    @input.type = "hidden"
    assert_equal "  foobar  ", @input.value
  end

  def test_hidden_to_text_sanitizes
    @input.type = "hidden"
    @input.value = INITIAL

    @input.type = "text"
    assert_equal "  foobar  ", @input.value
  end

  def test_number_to_url_composes_sanitizers
    @input.type = "number"
    @input.value = "foobar"
    assert_equal "", @input.value

    @input.type = "url"
    assert_equal "", @input.value
  end

  def test_range_falls_back_to_the_midpoint
    @input.type = "hidden"
    @input.value = INITIAL

    @input.type = "range"
    assert_equal "50", @input.value
  end

  def test_temporal_types_reject_a_non_date_value
    %w[date month week time datetime-local].each do |type|
      input = @doc.create_element("input")
      input.type = "hidden"
      input.value = INITIAL
      input.type = type
      assert_equal "", input.value, "type=#{type}"
    end
  end

  def test_becoming_selectable_resets_the_selection
    @input.type = "hidden"
    @input.value = INITIAL

    @input.type = "text"
    assert_equal 0, @input.selection_start
    assert_equal 0, @input.selection_end
    assert_equal "none", @input.selection_direction
  end

  def test_a_selectable_to_selectable_change_keeps_the_selection
    @input.type = "text"
    @input.value = "abcdef"
    @input.set_selection_range(1, 3, "backward")

    @input.type = "search"
    assert_equal 1, @input.selection_start
    assert_equal 3, @input.selection_end
    assert_equal "backward", @input.selection_direction
  end

  def test_changing_to_file_clears_the_value
    @input.type = "text"
    @input.value = INITIAL

    @input.type = "file"
    assert_equal "", @input.value
  end

  def test_attribute_write_paths_run_the_same_state_transition
    [
      ->(input, type) { input.type = type },
      ->(input, type) { input.set_attribute("type", type) },
      ->(input, type) { input.set_attribute_ns(nil, "type", type) },
      ->(input, type) { input.get_attribute_node("type").value = type }
    ].each do |write|
      input = @doc.create_element("input")
      input.type = "text"
      input.value = "not a number"
      write.call(input, "number")
      write.call(input, "text")
      assert_equal "", input.value, "sanitized values must not resurrect without a getter between writes"

      write.call(input, "hidden")
      input.value = "abcdef"
      write.call(input, "text")
      assert_equal 0, input.selection_start
    end
  end

  def test_removing_type_runs_the_transition_but_namespaced_type_does_not
    @input.type = "number"
    @input.value = "invalid"
    @input.remove_attribute("type")
    assert_equal "", @input.value

    @input.value = "abc"
    @input.set_attribute_ns("urn:test", "t:type", "number")
    assert_equal "text", @input.type
    assert_equal "abc", @input.value
  end

  def test_content_attribute_does_not_make_a_control_dirty
    @input.default_value = "first"
    @input.type = "search"
    @input.default_value = "second"
    assert_equal "second", @input.value

    @input.value = "assigned"
    @input.default_value = "third"
    assert_equal "assigned", @input.value
    @input.__internal_reset__
    assert_equal "third", @input.value
  end

  def test_pristine_and_dirty_color_values_are_distinct_even_for_black
    @input.type = "color"
    assert_equal "#000000", @input.value
    @input.type = "text"
    assert_equal "", @input.value

    @input.type = "color"
    @input.value = "#000000"
    @input.type = "text"
    assert_equal "#000000", @input.value

    @input.__internal_reset__
    @input.type = "color"
    @input.default_value = "#000000"
    @input.type = "text"
    @input.default_value = "new default"
    assert_equal "new default", @input.value
  end

  def test_current_value_is_transferred_to_the_default_mode_attribute
    @input.value = INITIAL
    @input.type = "hidden"
    assert_equal "  foobar  ", @input.default_value
    @input.value = "hidden value"
    assert_equal "hidden value", @input.get_attribute("value")
    @input.type = "text"
    @input.default_value = "new default"
    assert_equal "new default", @input.value
  end

  def test_type_mutation_is_recorded_before_the_value_attribute_transfer
    @input.value = "assigned"
    observer = Dommy::MutationObserver.new(@doc.default_view, proc { |_| })
    observer.__js_call__("observe", [@input, {"attributes" => true}])
    @input.type = "hidden"
    records = observer.__js_call__("takeRecords", []).to_a
    assert_equal %w[type value], records.map { |record| record.__js_get__("attributeName") }
  end

  def test_empty_current_value_does_not_overwrite_the_default
    @input.default_value = "default"
    @input.value = ""
    @input.type = "hidden"
    assert_equal "default", @input.value
  end

  def test_default_on_mode_uses_attribute_presence
    @input.type = "checkbox"
    assert_equal "on", @input.value
    @input.value = ""
    assert_equal "", @input.value
    assert_equal "", @input.default_value
    @input.remove_attribute("value")
    assert_equal "on", @input.value
  end

  def test_changing_to_file_clears_selected_files_but_same_state_does_not
    @input.type = "file"
    @input.files = [Dommy::File.new([], "example.txt")]
    assert_equal "C:\\fakepath\\example.txt", @input.value
    @input.type = "FILE"
    assert_equal 1, @input.files.length
    @input.type = "text"
    @input.type = "file"
    assert_equal 0, @input.files.length
    @input.files = [Dommy::File.new([], "example.txt")]
    @input.value = ""
    assert_equal 0, @input.files.length
  end

  def test_clone_preserves_current_value_and_dirty_flag_independently
    @input.default_value = "default"
    @input.type = "search"
    pristine = @input.clone_node(false)
    pristine.default_value = "new default"
    assert_equal "new default", pristine.value

    @input.value = "assigned"
    dirty = @input.clone_node(false)
    dirty.default_value = "new default"
    assert_equal "assigned", dirty.value
  end

  def test_range_clamps_rounds_and_handles_reversed_or_nonfinite_bounds
    @input.type = "range"
    @input.min = "0"
    @input.max = "100"
    @input.step = "20"
    @input.value = "invalid"
    assert_equal "60", @input.value
    @input.value = "200"
    assert_equal "100", @input.value
    @input.step = "any"
    @input.min = "10"
    @input.max = "5"
    @input.value = "invalid"
    assert_equal "10", @input.value
    @input.min = "1e999"
    @input.max = "1e999"
    @input.value = "1e999"
    assert_equal "50", @input.value
    @input.min = "0"
    @input.max = "1"
    @input.step = "0.1"
    @input.value = "0.6"
    assert_equal "0.6", @input.value
  end

  def test_temporal_sanitizers_reject_whitespace_and_use_gregorian_dates
    {"date" => "2026-10-05", "month" => "2026-10", "week" => "2026-W41",
     "time" => "12:30", "datetime-local" => "2026-10-05T12:30"}.each do |type, valid|
      @input.type = type
      @input.value = valid
      assert_equal valid, @input.value
      @input.value = " #{valid} "
      assert_equal "", @input.value, type
    end
    @input.type = "date"
    @input.value = "1500-02-29"
    assert_equal "", @input.value
    @input.value = "1582-10-10"
    assert_equal "1582-10-10", @input.value
  end

  def test_datetime_local_normalizes_valid_strings
    @input.type = "datetime-local"
    @input.value = "2026-10-05 12:30:00.000"
    assert_equal "2026-10-05T12:30", @input.value
    @input.value = "2026-10-05 12:30:01.010"
    assert_equal "2026-10-05T12:30:01.01", @input.value
    @input.value_as_number = 2.7343337071894478e26
    assert_equal "", @input.value
    @input.value = "10000-01-01T12:30"
    assert_equal "10000-01-01T12:30", @input.value
  end
end
