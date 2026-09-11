# frozen_string_literal: true

require_relative "test_helper"

# HTML gives some elements "attribute change steps": a details reacts to
# `open`, an option to `selected`, a select to `multiple` / `size`. The steps
# belong to the attribute changing, not to the method that changed it, so every
# write path runs them — `setAttributeNS` and `removeAttributeNS` included,
# which the setter overrides these used to be written as never saw.
class TestAttributeChangeSteps < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  def body(html)
    @doc.body.inner_html = html
    @doc.body
  end

  def selected_ids
    @doc.query_selector_all("option:checked").map { |o| o.get_attribute("id") }
  end

  def test_selected_removed_through_the_namespace_path_resettles_the_list
    body('<select><option id="a">A</option><option id="b" selected>B</option></select>')
    option = @doc.query_selector("#b")
    option.remove_attribute_ns(nil, "selected")
    # A single-select is never left with nothing selected at display size 1, so
    # dropping the only selected option's attribute falls back to the first.
    assert_equal(%w[a], selected_ids)
  end

  def test_selected_set_through_the_namespace_path_deselects_the_others
    body('<select><option id="a" selected>A</option><option id="b">B</option></select>')
    @doc.query_selector("#b").set_attribute_ns(nil, "selected", "")
    assert_equal(%w[b], selected_ids)
  end

  def test_multiple_removed_through_the_namespace_path_settles_the_list
    body('<select multiple><option id="a" selected>A</option><option id="b" selected>B</option></select>')
    assert_equal(%w[a b], selected_ids)
    @doc.query_selector("select").remove_attribute_ns(nil, "multiple")
    # Without `multiple` only the last selected option in tree order survives.
    assert_equal(%w[b], selected_ids)
  end

  def test_size_set_through_the_namespace_path_settles_the_list
    body('<select size="4"><option id="a">A</option><option id="b">B</option></select>')
    assert_empty(selected_ids)
    @doc.query_selector("select").set_attribute_ns(nil, "size", "1")
    # At display size 1 a list with nothing selected takes its first option.
    assert_equal(%w[a], selected_ids)
  end

  def test_open_set_through_the_namespace_path_fires_toggle
    body("<details><summary>s</summary>x</details>")
    details = @doc.query_selector("details")
    fired = nil
    details.add_event_listener("toggle", proc { |e| fired = [e.__js_get__("oldState"), e.__js_get__("newState")] })
    details.set_attribute_ns(nil, "open", "")
    @win.scheduler.advance_time(0)
    assert_equal(%w[closed open], fired)
  end

  def test_open_removed_through_the_namespace_path_fires_toggle
    body("<details open><summary>s</summary>x</details>")
    details = @doc.query_selector("details")
    @win.scheduler.advance_time(0)
    fired = nil
    details.add_event_listener("toggle", proc { |e| fired = [e.__js_get__("oldState"), e.__js_get__("newState")] })
    details.remove_attribute_ns(nil, "open")
    @win.scheduler.advance_time(0)
    assert_equal(%w[open closed], fired)
  end

  # `open` is a boolean attribute: its presence is the state, so rewriting it
  # with a different value is not a toggle.
  def test_rewriting_open_with_another_value_is_not_a_toggle
    body("<details open><summary>s</summary>x</details>")
    details = @doc.query_selector("details")
    @win.scheduler.advance_time(0)
    fired = 0
    details.add_event_listener("toggle", proc { fired += 1 })
    details.set_attribute("open", "open")
    @win.scheduler.advance_time(0)
    assert_equal(0, fired)
    assert(details.open)
  end

  def test_name_set_through_the_namespace_path_closes_the_group_peer
    body('<details name="g" open id="a"><summary>a</summary></details>' \
         '<details id="b" open><summary>b</summary></details>')
    @doc.query_selector("#b").set_attribute_ns(nil, "name", "g")
    # Joining a group that already has an open member closes the arriving one.
    refute(@doc.query_selector("#b").open)
    assert(@doc.query_selector("#a").open)
  end
end
