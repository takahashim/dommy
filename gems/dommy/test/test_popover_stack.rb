# frozen_string_literal: true

require_relative "test_helper"

# HTML's popover stacks: showing an auto popover closes the auto popovers it
# is not nested in, hiding one closes those shown above it, and a dialog
# shown with show() or showModal() closes every auto popover it is not
# nested in.
class TestPopoverStack < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <div id="a" popover>
        <div id="a1" popover>
          <dialog id="inner">inner</dialog>
        </div>
      </div>
      <div id="b" popover></div>
      <div id="m" popover="manual"></div>
      <dialog id="d">dialog</dialog>
    HTML
    @doc = @win.document
  end

  def el(id) = @doc.get_element_by_id(id)

  def test_showing_an_auto_popover_closes_one_it_is_not_nested_in
    el("a").show_popover
    el("b").show_popover
    assert_equal %w[b], showing_ids
  end

  def test_a_nested_auto_popover_keeps_its_ancestor_open
    el("a").show_popover
    el("a1").show_popover
    assert_equal %w[a a1], showing_ids
  end

  def test_hiding_a_popover_hides_those_shown_above_it
    el("a").show_popover
    el("a1").show_popover
    el("a").hide_popover
    assert_empty showing_ids
  end

  def test_a_manual_popover_stays_open
    el("m").show_popover
    el("a").show_popover
    assert_equal %w[a m], showing_ids
  end

  def test_closing_popovers_fire_their_events
    el("a").show_popover
    @win.scheduler.advance_time(0)
    events = []
    el("a").add_event_listener("beforetoggle", proc { |e| events << ["beforetoggle", e.__js_get__("newState")] })
    el("a").add_event_listener("toggle", proc { |e| events << ["toggle", e.__js_get__("newState")] })
    el("b").show_popover
    @win.scheduler.advance_time(0)
    assert_equal [%w[beforetoggle closed], %w[toggle closed]], events
  end

  # A popover cannot be shown from a beforetoggle listener while another one
  # is being shown.
  def test_showing_from_a_showing_beforetoggle_throws
    error = nil
    el("a").add_event_listener("beforetoggle", proc do
      el("b").show_popover
    rescue Dommy::DOMException::InvalidStateError => e
      error = e
    end)
    el("a").show_popover
    assert error
    assert_equal %w[a], showing_ids
  end

  def test_dialog_show_closes_the_auto_popovers_it_is_not_in
    el("a").show_popover
    el("m").show_popover
    el("d").show
    assert_equal %w[m], showing_ids
  end

  def test_dialog_show_modal_keeps_the_popovers_it_is_nested_in
    el("a").show_popover
    el("a1").show_popover
    el("inner").show_modal
    assert_equal %w[a a1], showing_ids
  end

  # A dialog that is also showing as an auto popover is no descendant of
  # itself, so show() hides it as a popover (WPT toggle-events.html).
  def test_dialog_show_hides_itself_as_a_popover
    dialog = el("d")
    dialog.set_attribute("popover", "")
    toggles = []
    dialog.add_event_listener("toggle", proc { |e| toggles << [e.__js_get__("oldState"), e.__js_get__("newState")] })
    dialog.add_event_listener("beforetoggle", proc { dialog.show_popover }, { "once" => true })

    dialog.show
    assert dialog.has_attribute?("open")
    refute dialog.__send__(:popover_showing?)
    @win.scheduler.advance_time(0)
    assert_equal [%w[closed open], %w[closed closed]], toggles
  end

  def test_removing_a_showing_popover_hides_it_without_events
    el("a").show_popover
    @win.scheduler.advance_time(0)
    events = []
    el("a").add_event_listener("beforetoggle", proc { |e| events << e.type })
    el("a").add_event_listener("toggle", proc { |e| events << e.type })
    @doc.body.append_child(el("a").tap(&:remove))
    @win.scheduler.advance_time(0)
    assert_empty events
    assert_empty showing_ids
  end

  def test_changing_the_popover_state_hides_a_showing_popover
    el("a").show_popover
    el("a").set_attribute("popover", "auto")
    assert_equal %w[a], showing_ids, "the same state"
    el("a").set_attribute("popover", "manual")
    assert_empty showing_ids
  end

  # Removing the attribute leaves no popover for the validity checks to
  # accept, but the attribute change steps still end its showing state.
  def test_removing_the_popover_attribute_hides_a_showing_popover
    el("a").show_popover
    events = []
    el("a").add_event_listener("beforetoggle", proc { |e| events << e.__js_get__("newState") })
    el("a").remove_attribute("popover")
    assert_equal %w[closed], events
    assert_empty showing_ids

    el("b").show_popover
    assert_equal [el("b")], @doc.__internal_popover_stack__.list("auto")
  end

  # The checks after beforetoggle compare against the document the show
  # began in, so a listener that moves the element away makes it throw.
  def test_moving_to_another_document_in_beforetoggle_throws
    other = @doc.implementation.create_html_document("")
    popover = el("b")
    popover.add_event_listener("beforetoggle", proc { other.body.append_child(popover) })
    assert_raises(Dommy::DOMException::InvalidStateError) { popover.show_popover }
    refute popover.__send__(:popover_showing?)
    assert_empty @doc.__internal_popover_stack__.list("auto")
    assert_empty other.__internal_popover_stack__.list("auto")
  end

  private

  # The popovers in the popover showing state; Dommy matches no
  # :popover-open to read it from outside.
  def showing_ids
    %w[a a1 b m].select { |id| el(id).__send__(:popover_showing?) }
  end
end
