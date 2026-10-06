# frozen_string_literal: true

require_relative "test_helper"

# <dialog>: the focusing steps on show/showModal, the focus coming back on
# close, the modal dialog's inert outside, requestClose() and closedBy, the
# dialog commands, and the removing steps.
class TestDialogFocusAndClose < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <button id="outside">outside</button>
      <dialog id="d"><p>text</p><input id="first"><input id="auto" autofocus></dialog>
      <dialog id="plain"><p>nothing focusable</p></dialog>
      <button id="opener" commandfor="d" command="show-modal" value="v">open</button>
      <button id="closer" commandfor="d" command="close" value="closed-by-button">close</button>
    HTML
    @doc = @win.document
  end

  def el(id) = @doc.get_element_by_id(id)

  def test_show_modal_focuses_the_autofocus_descendant_and_close_restores
    el("outside").focus
    el("d").show_modal
    assert_same el("auto"), @doc.active_element
    el("d").close
    assert_same el("outside"), @doc.active_element
  end

  def test_a_dialog_without_a_focusable_descendant_focuses_itself
    el("plain").show_modal
    assert_same el("plain"), @doc.active_element
  end

  def test_a_modal_dialog_makes_the_rest_of_the_document_inert
    el("d").show_modal
    assert Dommy::Internal::Focusability.inert?(el("outside"))
    refute Dommy::Internal::Focusability.inert?(el("first"))
    el("outside").focus
    assert_same el("auto"), @doc.active_element
    el("d").close
    refute Dommy::Internal::Focusability.inert?(el("outside"))
  end

  def test_removing_a_modal_dialog_clears_is_modal_and_unblocks
    dialog = el("d")
    dialog.show_modal
    dialog.remove
    refute dialog.__internal_modal__?
    refute Dommy::Internal::Focusability.inert?(el("outside"))
  end

  def test_request_close_fires_a_cancelable_cancel
    events = []
    el("d").add_event_listener("cancel", proc { |e| events << e.__js_get__("cancelable") })
    el("d").show
    el("d").request_close("rv")
    refute el("d").open
    assert_equal "rv", el("d").return_value
    assert_equal [true], events
  end

  def test_a_canceled_request_close_keeps_the_dialog_open
    el("d").add_event_listener("cancel", proc { |e| e.__js_call__("preventDefault", []) })
    el("d").show
    el("d").request_close
    assert el("d").open
  end

  def test_closed_by
    assert_equal "none", el("d").closed_by
    el("d").show_modal
    assert_equal "closerequest", el("d").closed_by
    el("d").set_attribute("closedby", "ANY")
    assert_equal "any", el("d").closed_by
  end

  def test_dialog_commands_pass_the_source_and_its_value
    sources = []
    el("d").add_event_listener("beforetoggle", proc { |e| sources << e.source&.id })
    el("opener").click
    assert el("d").matches?(":modal")
    el("closer").click
    refute el("d").open
    assert_equal "closed-by-button", el("d").return_value
    assert_equal %w[opener closer], sources
  end
end
