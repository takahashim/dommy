# frozen_string_literal: true

require_relative "test_helper"

# EventSynthesis.drag_and_drop: HTML's drag-and-drop processing model for a
# mouse drag, and the plain pointer move when nothing is draggable.
class TestDragAndDrop < Minitest::Test
  include DommyTestHelper

  TYPES = %w[pointerdown mousedown dragstart pointercancel drag dragenter dragleave dragover drop dragend
             mouseout mouseover pointermove mousemove pointerup mouseup].freeze

  def setup
    @win = make_window('<ul><li id="a" draggable="true">A</li><li id="b">B</li><li id="c">C</li></ul>')
    @doc = @win.document
    @a = @doc.get_element_by_id("a")
    @b = @doc.get_element_by_id("b")
    @log = []
    TYPES.each do |type|
      @doc.add_event_listener(type, ->(e) { @log << "#{e.type}@#{name_of(e.__js_get__("target"))}" })
    end
  end

  def name_of(node)
    id = node.get_attribute("id")
    id.to_s.empty? ? node.local_name : id
  end

  def prevent(event) = event.__js_call__("preventDefault", [])

  def accept_drops_on(element, effect: "move")
    element.add_event_listener("dragenter", ->(e) { prevent(e) })
    element.add_event_listener("dragover", lambda { |e|
      prevent(e)
      e.data_transfer.drop_effect = effect
    })
  end

  def drag(source = @a, target = @b, **options)
    Dommy::Interaction::EventSynthesis.drag_and_drop(source, target, **options)
  end

  def test_a_drop_target_gets_the_drag_from_dragstart_to_dragend
    accept_drops_on(@b)
    @b.add_event_listener("drop", ->(e) { prevent(e) })

    assert drag
    assert_equal %w[pointerdown@a mousedown@a dragstart@a pointercancel@a
                    drag@a dragenter@a dragenter@body dragover@body
                    drag@a dragenter@b dragleave@body dragover@b
                    drop@b dragend@a], @log
  end

  def test_without_an_accepting_dragover_there_is_no_drop
    refute drag
    assert_equal %w[drag@a dragenter@b dragover@body dragleave@body dragend@a], @log.last(5)
  end

  def test_a_canceled_dragstart_starts_no_drag
    @a.add_event_listener("dragstart", ->(e) { prevent(e) })

    refute drag
    assert_equal %w[pointerdown@a mousedown@a dragstart@a], @log
  end

  def test_a_canceled_drag_ends_the_drag_without_a_drop
    accept_drops_on(@b)
    @a.add_event_listener("drag", ->(e) { prevent(e) })

    refute drag
    assert_equal %w[dragstart@a pointercancel@a drag@a dragend@a], @log.last(4)
  end

  def test_the_drag_data_store_is_writable_in_dragstart_and_readable_in_drop
    accept_drops_on(@b)
    seen = {}
    @a.add_event_listener("dragstart", ->(e) { e.data_transfer.set_data("text", "A") })
    @b.add_event_listener("dragover", lambda { |e|
      e.data_transfer.set_data("text/plain", "changed")
      seen[:over] = [e.data_transfer.get_data("text"), e.data_transfer.types]
    })
    @b.add_event_listener("drop", lambda { |e|
      e.data_transfer.set_data("text/plain", "changed")
      seen[:drop] = e.data_transfer.get_data("text")
    })

    drag
    assert_equal ["", ["text/plain"]], seen[:over]
    assert_equal "A", seen[:drop]
  end

  def test_drop_and_dragend_carry_the_drag_operation
    accept_drops_on(@b, effect: "copy")
    effects = []
    @b.add_event_listener("drop", ->(e) { effects << e.data_transfer.drop_effect })
    @a.add_event_listener("dragend", ->(e) { effects << e.data_transfer.drop_effect })

    drag
    assert_equal %w[copy copy], effects
  end

  def test_an_effect_allowed_that_excludes_the_drop_effect_refuses_the_drop
    accept_drops_on(@b, effect: "move")
    @a.add_event_listener("dragstart", ->(e) { e.data_transfer.effect_allowed = "copy" })

    refute drag
  end

  def test_a_link_drags_its_url
    win = make_window('<a id="l" href="https://example.org/x">x</a><p id="t">t</p>')
    link = win.document.get_element_by_id("l")
    target = win.document.get_element_by_id("t")
    accept_drops_on(target)
    dropped = nil
    target.add_event_listener("drop", ->(e) { dropped = e.data_transfer.get_data("url") })

    Dommy::Interaction::EventSynthesis.drag_and_drop(link, target)
    assert_equal "https://example.org/x", dropped
  end

  def test_the_press_inside_a_draggable_element_drags_that_element
    win = make_window('<div id="item" draggable="true"><span id="handle">=</span></div><p id="t">t</p>')
    starts = []
    win.document.add_event_listener("dragstart", ->(e) { starts << name_of(e.__js_get__("target")) })

    Dommy::Interaction::EventSynthesis.drag_and_drop(win.document.get_element_by_id("handle"),
      win.document.get_element_by_id("t"))
    assert_equal ["item"], starts
  end

  def test_with_nothing_draggable_the_pointer_moves_and_releases_on_the_target
    refute drag(@b, @doc.get_element_by_id("c"))
    assert_equal %w[pointerdown@b mousedown@b mouseout@b mouseover@c pointermove@c mousemove@c
                    pointerup@c mouseup@c], @log
  end

  def test_a_canceled_mousedown_starts_no_drag
    @a.add_event_listener("mousedown", ->(e) { prevent(e) })

    drag
    refute_includes @log, "dragstart@a"
    assert_equal %w[pointerup@b mouseup@b], @log.last(2)
  end

  def test_html5_false_moves_the_pointer_even_from_a_draggable_element
    drag(html5: false)
    refute_includes @log, "dragstart@a"
    assert_includes @log, "mouseup@b"
  end

  def test_pause_runs_between_the_steps
    pauses = 0
    accept_drops_on(@b)
    drag(pause: -> { pauses += 1 })
    assert_equal 3, pauses
  end
end
