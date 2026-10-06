# frozen_string_literal: true

require_relative "test_helper"

# :popover-open, :open and :modal (HTML §"Pseudo-classes"), and the UA
# rules that hide a popover that is not showing.
class TestOpenStatePseudoClasses < Minitest::Test
  include DommyTestHelper

  def setup
    @win = make_window(<<~HTML)
      <div id="p" popover>pop</div>
      <details id="det"><summary>s</summary>x</details>
      <dialog id="d">dialog</dialog>
      <dialog id="dp" popover>dialog popover</dialog>
    HTML
    @doc = @win.document
  end

  def el(id) = @doc.get_element_by_id(id)

  def display(id) = @win.get_computed_style(el(id)).get_property_value("display")

  def test_popover_open_tracks_the_showing_state
    refute el("p").matches?(":popover-open")
    assert_empty @doc.query_selector_all(":popover-open").to_a
    el("p").show_popover
    assert el("p").matches?(":popover-open")
    assert_equal [el("p")], @doc.query_selector_all(":popover-open").to_a
    el("p").hide_popover
    refute el("p").matches?(":popover-open")
  end

  def test_a_closed_popover_is_not_rendered
    assert_equal "none", display("p")
    el("p").show_popover
    assert_equal "block", display("p")
    el("p").hide_popover
    assert_equal "none", display("p")
  end

  def test_adding_the_popover_attribute_hides_the_element
    div = @doc.create_element("div")
    @doc.body.append_child(div)
    assert_equal "block", @win.get_computed_style(div).get_property_value("display")
    div.set_attribute("popover", "manual")
    assert_equal "none", @win.get_computed_style(div).get_property_value("display")
  end

  def test_an_open_dialog_with_a_popover_attribute_stays_rendered
    el("dp").show
    assert_equal "block", display("dp")
    el("dp").close
    assert_equal "none", display("dp")
    el("dp").show_popover
    assert_equal "block", display("dp")
  end

  def test_open_matches_details_and_dialog_with_open
    refute el("det").matches?(":open")
    el("det").open = true
    assert el("det").matches?(":open")
    refute el("d").matches?(":open")
    el("d").show
    assert el("d").matches?(":open")
    refute el("p").matches?(":open")
  end

  def test_modal_matches_a_modal_dialog_only
    el("d").show
    refute el("d").matches?(":modal")
    el("d").close
    el("d").show_modal
    assert el("d").matches?(":modal")
    assert_equal "fixed", display_prop("d", "position")
    el("d").close
    refute el("d").matches?(":modal")
  end

  def test_modal_matches_the_fullscreen_element
    el("p").request_fullscreen
    assert el("p").matches?(":modal")
    assert el("p").matches?(":fullscreen")
    @doc.exit_fullscreen
    refute el("p").matches?(":modal")
  end

  private

  def display_prop(id, name) = @win.get_computed_style(el(id)).get_property_value(name)
end
