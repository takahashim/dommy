# frozen_string_literal: true

require_relative "../test_helper"

# WPT-derived coverage for the second batch of spec-strictness fixes:
#   - Document.createElement validates the name
#   - MutationRecord exposes previousSibling / nextSibling
#   - AbortSignal.abort() / .timeout() / .any() static methods
class TestWPTCreateElementValidation < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window
    @doc = @win.document
  end

  # WPT: dom/nodes/Document-createElement.html

  def test_empty_name_throws_InvalidCharacterError
    assert_raises(Dommy::DOMException::InvalidCharacterError) { @doc.create_element("") }
  end

  def test_name_with_space_throws
    assert_raises(Dommy::DOMException::InvalidCharacterError) { @doc.create_element("a b") }
  end

  def test_name_starting_with_digit_throws
    assert_raises(Dommy::DOMException::InvalidCharacterError) { @doc.create_element("1abc") }
  end

  def test_name_with_lt_throws
    assert_raises(Dommy::DOMException::InvalidCharacterError) { @doc.create_element("a<b") }
  end

  def test_name_with_gt_throws
    assert_raises(Dommy::DOMException::InvalidCharacterError) { @doc.create_element("a>b") }
  end

  def test_name_with_slash_throws
    assert_raises(Dommy::DOMException::InvalidCharacterError) { @doc.create_element("a/b") }
  end

  def test_valid_hyphenated_name_accepted
    el = @doc.create_element("my-card")
    assert_equal("MY-CARD", el.tag_name)
  end

  def test_valid_uppercase_lowercased
    el = @doc.create_element("DIV")
    # tag_name normalizes uppercase for HTML
    assert_equal("DIV", el.tag_name)
    assert_equal("div", el.__node__.name)
  end

  def test_createAttribute_empty_throws
    assert_raises(Dommy::DOMException::InvalidCharacterError) { @doc.create_attribute("") }
  end

  def test_createAttribute_whitespace_throws
    assert_raises(Dommy::DOMException::InvalidCharacterError) { @doc.create_attribute("a b") }
  end

  def test_createElementNS_invalid_qname_throws
    assert_raises(Dommy::DOMException::InvalidCharacterError) do
      @doc.create_element_ns("ns", "1bad")
    end
  end
end

class TestWPTMutationRecordSiblings < Minitest::Test
  include DommyTestHelper

  def setup
    # Compact HTML — extra whitespace would parse as text-node
    # siblings and make sibling assertions fragile.
    @win = make_window("<ul id='root'><li id='a'>A</li><li id='c'>C</li></ul>")
    @doc = @win.document
    @root = @doc.get_element_by_id("root")
    @records = []
    @obs = Dommy::MutationObserver.new(@win, proc { |recs| @records.concat(recs) })
  end

  def teardown
    @obs.__js_call__("disconnect", [])
  end

  # WPT: dom/nodes/MutationObserver-childList.html

  def test_append_records_previous_sibling
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    new_el = @doc.create_element("li")
    @root.append_child(new_el)
    @win.scheduler.drain_microtasks
    rec = @records.first
    refute_nil(rec.previous_sibling)
    assert_equal("c", rec.previous_sibling.id)
    assert_nil(rec.next_sibling)
  end

  def test_prepend_records_next_sibling
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    new_el = @doc.create_element("li")
    @root.prepend(new_el)
    @win.scheduler.drain_microtasks
    rec = @records.first
    assert_nil(rec.previous_sibling)
    refute_nil(rec.next_sibling)
    assert_equal("a", rec.next_sibling.id)
  end

  def test_insert_between_records_both_siblings
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    new_el = @doc.create_element("li")
    @root.insert_before(new_el, @doc.get_element_by_id("c"))
    @win.scheduler.drain_microtasks
    rec = @records.first
    refute_nil(rec.previous_sibling)
    refute_nil(rec.next_sibling)
    assert_equal("a", rec.previous_sibling.id)
    assert_equal("c", rec.next_sibling.id)
  end

  def test_js_bridge_exposes_siblings
    @obs.__js_call__("observe", [@root, {"childList" => true}])
    @root.append_child(@doc.create_element("li"))
    @win.scheduler.drain_microtasks
    rec = @records.first
    assert_same(rec.previous_sibling, rec.__js_get__("previousSibling"))
    if rec.next_sibling
      assert_same(rec.next_sibling, rec.__js_get__("nextSibling"))
    else
      assert_nil(rec.__js_get__("nextSibling"))
    end
  end
end

class TestWPTAbortSignalStatic < Minitest::Test
  # WPT: dom/abort/abort-signal-any.html, abort-signal-timeout.html,
  # abort-signal-abort.html

  def test_AbortSignal_abort_returns_aborted_signal
    s = Dommy::AbortSignal.abort
    assert(s.aborted?)
  end

  def test_AbortSignal_abort_with_reason
    err = RuntimeError.new("cancelled")
    s = Dommy::AbortSignal.abort(err)
    assert(s.aborted?)
    assert_same(err, s.reason)
  end

  def test_AbortSignal_abort_string_reason
    s = Dommy::AbortSignal.abort("user")
    assert_equal("user", s.reason)
  end

  def test_AbortSignal_abort_can_throw_if_aborted
    s = Dommy::AbortSignal.abort(RuntimeError.new("x"))
    assert_raises(RuntimeError) { s.throw_if_aborted }
  end

  def test_AbortSignal_any_with_no_pre_aborted_inputs
    a = Dommy::AbortController.new
    b = Dommy::AbortController.new
    composite = Dommy::AbortSignal.any([a.signal, b.signal])
    refute(composite.aborted?)
    a.__js_call__("abort", ["boom"])
    assert(composite.aborted?)
    assert_equal("boom", composite.reason)
  end

  def test_AbortSignal_any_with_already_aborted_input
    a = Dommy::AbortController.new
    a.__js_call__("abort", ["early"])
    b = Dommy::AbortController.new
    composite = Dommy::AbortSignal.any([a.signal, b.signal])
    assert(composite.aborted?)
    assert_equal("early", composite.reason)
  end

  def test_AbortSignal_any_aborts_with_first_aborter
    a = Dommy::AbortController.new
    b = Dommy::AbortController.new
    composite = Dommy::AbortSignal.any([a.signal, b.signal])
    b.__js_call__("abort", ["b first"])
    assert(composite.aborted?)
    assert_equal("b first", composite.reason)
  end

  def test_AbortSignal_any_ignores_non_signal_inputs
    a = Dommy::AbortController.new
    composite = Dommy::AbortSignal.any([a.signal, "not a signal", nil])
    refute(composite.aborted?)
    a.__js_call__("abort", ["x"])
    assert(composite.aborted?)
  end

  def test_AbortSignal_timeout_with_scheduler_fires_after_delay
    win = Dommy.new_window
    s = Dommy::AbortSignal.timeout(0, scheduler: win.scheduler)
    refute(s.aborted?)
    win.scheduler.advance_time(1)
    assert(s.aborted?)
    assert_kind_of(Dommy::DOMException::TimeoutError, s.reason)
  end
end
