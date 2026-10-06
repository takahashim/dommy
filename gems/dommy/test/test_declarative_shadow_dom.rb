# frozen_string_literal: true

require_relative "test_helper"

# ShadowRoot state (DOM: clonable, serializable, declarative, available to
# element internals) and attachShadow()'s ShadowRootInit.
class TestShadowRootInitState < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window("<div id='host'></div>")
    @doc = @win.document
    @host = @doc.get_element_by_id("host")
  end

  def test_flags_default_to_false
    root = @host.attach_shadow({"mode" => "open"})
    refute root.clonable
    refute root.serializable
    refute root.__internal_declarative__?
    assert_equal false, root.__js_get__("clonable")
    assert_equal false, root.__js_get__("serializable")
  end

  def test_init_sets_clonable_and_serializable
    root = @host.attach_shadow({"mode" => "open", "clonable" => true, "serializable" => 1})
    assert_equal true, root.__js_get__("clonable")
    assert_equal true, root.__js_get__("serializable")
  end

  def test_slot_assignment_is_an_enum
    assert_raises(Dommy::Bridge::TypeError) { @host.attach_shadow({"mode" => "open", "slotAssignment" => "bogus"}) }
    root = @host.attach_shadow({"mode" => "open", "slotAssignment" => "manual"})
    assert_equal "manual", root.slot_assignment
  end

  # The dictionary is converted before the algorithm runs: a missing mode on
  # an element that cannot host a shadow root is still a TypeError.
  def test_dictionary_conversion_precedes_the_host_check
    span = @doc.create_element("input")
    assert_raises(Dommy::Bridge::TypeError) { span.attach_shadow({}) }
    assert_raises(Dommy::DOMException::NotSupportedError) { span.attach_shadow({"mode" => "open"}) }
  end

  # attach a shadow root step 4: a declarative shadow root of the same mode
  # is emptied, stops being declarative, and is returned.
  def test_attach_over_a_declarative_root_empties_and_returns_it
    root = @host.attach_shadow({"mode" => "open"})
    root.inner_html = "<span>a</span><b>b</b>"
    root.__internal_declarative__ = true
    assert_raises(Dommy::DOMException::NotSupportedError) { @host.attach_shadow({"mode" => "closed"}) }
    again = @host.attach_shadow({"mode" => "open"})
    assert_same root, again
    assert_equal 0, root.child_nodes.length
    refute root.__internal_declarative__?
    assert_raises(Dommy::DOMException::NotSupportedError) { @host.attach_shadow({"mode" => "open"}) }
  end

  def test_attach_over_an_imperative_root_throws
    @host.attach_shadow({"mode" => "open"})
    assert_raises(Dommy::DOMException::NotSupportedError) { @host.attach_shadow({"mode" => "open"}) }
  end

  # Emptying a declarative root removes the children one at a time, in tree
  # order: a MutationObserver sees one record per child.
  def test_emptying_a_declarative_root_queues_a_record_per_child
    root = @host.attach_shadow({"mode" => "open"})
    root.inner_html = "<i></i><b></b>"
    root.__internal_declarative__ = true
    observer = Dommy::MutationObserver.new(@win, proc {})
    observer.__js_call__("observe", [root, {"childList" => true}])
    @host.attach_shadow({"mode" => "open"})
    records = observer.__js_call__("takeRecords", [])
    assert_equal 2, records.size
    assert_equal(%w[I B], records.map { |r| r.__js_get__("removedNodes").first.tag_name })
  end
end
