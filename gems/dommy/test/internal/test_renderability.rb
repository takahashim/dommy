# frozen_string_literal: true

require_relative "../test_helper"

# getComputedStyle asks Renderability whether an element is rendered before it
# computes anything: a non-rendered element has an empty computed style. The
# flat-tree check walks ancestors for a shadow host, but short-circuits when
# the document has no shadow roots at all (no host is possible), so these pin
# both sides of that short-circuit.
class TestRenderability < Minitest::Test
  include DommyTestHelper

  def color(win, el) = win.get_computed_style(el).get_property_value("color")

  # No shadow roots: the short-circuit skips the ancestor walk, and a deeply
  # nested element still gets its normal computed style.
  def test_deep_element_without_shadow_roots_is_rendered
    nest = (1..20).reduce("<a id='leaf'>x</a>") { |inner, d| "<div class='d#{d}'>#{inner}</div>" }
    win = make_window("<style>#leaf { color: rgb(1, 2, 3) }</style>#{nest}")
    refute win.document.__internal_any_shadow_roots__?
    assert_equal "rgb(1, 2, 3)", color(win, win.document.get_element_by_id("leaf"))
  end

  # A light child of a shadow host that is not assigned to a slot is outside
  # the flat tree, so it is not rendered and its computed style is empty — the
  # walk still runs because the document now has a shadow root.
  def test_unslotted_light_child_of_a_host_is_not_rendered
    win = make_window("<style>#light { color: rgb(1, 2, 3) }</style>" \
                      "<my-el id='host'><span id='light'>L</span></my-el>")
    host = win.document.get_element_by_id("host")
    host.attach_shadow("mode" => "open").inner_html = "<slot name='s'></slot>"
    assert win.document.__internal_any_shadow_roots__?
    # #light has no slot= attribute, so it is unslotted and outside the flat tree.
    assert_equal "", color(win, win.document.get_element_by_id("light"))
  end

  # An assigned light child is in the flat tree and rendered as usual.
  def test_slotted_light_child_is_rendered
    win = make_window("<style>#light { color: rgb(4, 5, 6) }</style>" \
                      "<my-el id='host'><span id='light' slot='s'>L</span></my-el>")
    host = win.document.get_element_by_id("host")
    host.attach_shadow("mode" => "open").inner_html = "<slot name='s'></slot>"
    assert_equal "rgb(4, 5, 6)", color(win, win.document.get_element_by_id("light"))
  end
end
