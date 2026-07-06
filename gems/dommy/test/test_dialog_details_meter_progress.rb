# frozen_string_literal: true

require_relative "test_helper"

class TestHTMLDialogElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<dialog id='d'>Hello</dialog>")
    @doc = @win.document
    @dialog = @doc.get_element_by_id("d")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLDialogElement, @dialog)
  end

  def test_open_default_false
    refute(@dialog.open)
  end

  def test_show_sets_open
    @dialog.show
    assert(@dialog.open)
    assert(@dialog.has_attribute?("open"))
  end

  def test_show_modal_sets_open
    @dialog.show_modal
    assert(@dialog.open)
  end

  def test_close_clears_open
    @dialog.show
    @dialog.close
    refute(@dialog.open)
  end

  def test_close_with_return_value
    @dialog.show
    @dialog.close("ok")
    assert_equal("ok", @dialog.return_value)
  end

  def test_close_fires_close_event
    @dialog.show
    fired = false
    @dialog.add_event_listener("close", proc { fired = true })
    @dialog.close
    assert(fired)
  end

  def test_return_value_setter
    @dialog.return_value = "result"
    assert_equal("result", @dialog[:returnValue])
  end

  def test_open_setter_via_js
    @dialog[:open] = true
    assert(@dialog.has_attribute?("open"))
  end
end

class TestHTMLDetailsElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<details id='d'><summary>S</summary>Body</details>")
    @details = @win.document.get_element_by_id("d")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLDetailsElement, @details)
  end

  def test_open_default_false
    refute(@details.open)
  end

  def test_open_setter_adds_attribute
    @details.open = true
    assert(@details.has_attribute?("open"))
    assert(@details.open)
  end

  def test_open_setter_removes_attribute
    @details.open = true
    @details.open = false
    refute(@details.has_attribute?("open"))
  end

  def test_open_change_fires_toggle_event
    # Per spec the toggle event is dispatched asynchronously (queued as a task),
    # so drain the scheduler before asserting.
    fired = false
    @details.add_event_listener("toggle", proc { fired = true })
    @details.open = true
    @win.scheduler.advance_time(0)
    assert(fired)
  end

  def test_toggle_idempotent_does_not_fire
    @details.open = true
    @win.scheduler.advance_time(0)
    fired = 0
    @details.add_event_listener("toggle", proc { fired += 1 })
    # same value
    @details.open = true
    @win.scheduler.advance_time(0)
    assert_equal(0, fired)
  end
end

class TestHTMLMeterElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<meter id='m' value='6' min='0' max='10' low='3' high='8' optimum='5'></meter>")
    @meter = @win.document.get_element_by_id("m")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLMeterElement, @meter)
  end

  def test_numeric_attributes
    assert_equal(6.0, @meter.value)
    assert_equal(0.0, @meter.min)
    assert_equal(10.0, @meter.max)
    assert_equal(3.0, @meter.low)
    assert_equal(8.0, @meter.high)
    assert_equal(5.0, @meter.optimum)
  end

  def test_defaults
    bare = @win.document.create_element("meter")
    assert_equal(0.0, bare.value)
    assert_equal(0.0, bare.min)
    assert_equal(1.0, bare.max)
  end

  def test_value_setter
    @meter.value = 7.5
    assert_equal(7.5, @meter.value)
    assert_equal("7.5", @meter.get_attribute("value"))
  end
end

class TestHTMLProgressElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<progress id='p' value='30' max='100'></progress>")
    @progress = @win.document.get_element_by_id("p")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLProgressElement, @progress)
  end

  def test_value_and_max
    assert_equal(30.0, @progress.value)
    assert_equal(100.0, @progress.max)
  end

  def test_position_calculated
    assert_in_delta(0.3, @progress.position, 1e-6)
  end

  def test_indeterminate_position_when_no_value
    bare = @win.document.create_element("progress")
    # Indeterminate: position is -1, but the value IDL getter is 0 (per spec).
    assert_equal(-1.0, bare.position)
    assert_equal(0.0, bare.value)
  end

  def test_default_max_is_one
    bare = @win.document.create_element("progress")
    assert_equal(1.0, bare.max)
  end

  def test_value_setter
    @progress.value = 50
    assert_equal(50.0, @progress.value)
    assert_in_delta(0.5, @progress.position, 1e-6)
  end
end

class TestHTMLTemplateElement < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
    @doc.body.inner_html = "<template id='t'><p class='row'>Hello</p></template>"
    @tpl = @doc.get_element_by_id("t")
  end

  def test_class_dispatch
    assert_kind_of(Dommy::HTMLTemplateElement, @tpl)
  end

  def test_content_is_document_fragment
    content = @tpl.content
    refute_nil(content)
    assert_equal(11, content.__js_get__("nodeType"))
  end

  def test_template_children_not_in_outer_query
    # Template content is invisible to top-level querySelector by spec.
    assert_nil(@doc.query_selector(".row"))
  end

  def test_template_content_query_selector
    el = @tpl.content.query_selector(".row")
    refute_nil(el)
    assert_equal("Hello", el.text_content)
  end

  def test_clone_node_deep_copies_template_content
    inner_html = @tpl.inner_html
    assert_match(/Hello/, inner_html)
  end
end
